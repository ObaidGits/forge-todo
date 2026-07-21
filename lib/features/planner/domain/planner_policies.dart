import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';

/// The as-of-close classification of a task captured in a factual close.
enum CloseTaskStatus {
  /// Eligible and completed at or before the factual close.
  completed('completed'),

  /// Eligible planned task incomplete at the planning-day boundary (R-PLAN-003).
  missed('missed'),

  /// Eligible (due but not planned) task incomplete at the boundary.
  incomplete('incomplete'),

  /// Cancelled before period close; excluded from the eligible set (R-HOME-004).
  cancelled('cancelled');

  const CloseTaskStatus(this.wire);

  final String wire;
}

/// The immutable facts about one task observed at factual close.
///
/// These are the raw inputs the close snapshot records so metrics are always
/// reproducible from source (R-INSIGHT-004). Whether a task is "missed" or
/// merely "incomplete" is derived, not stored by the caller.
final class CloseTaskFact {
  const CloseTaskFact({
    required this.entityId,
    required this.isPlanned,
    required this.isDue,
    required this.completedAtOrBeforeBoundary,
    this.cancelledBeforeClose = false,
    this.taskDueDate,
    this.sourceEventId,
  });

  final String entityId;

  /// True when the task is referenced by a `planned` entry in this period.
  final bool isPlanned;

  /// True when the task's due date/instant falls in the planning-day interval.
  final bool isDue;

  /// True when the task has a completion event at or before the boundary.
  final bool completedAtOrBeforeBoundary;

  /// True when the task was cancelled before period close (excluded from
  /// eligibility, R-HOME-004).
  final bool cancelledBeforeClose;

  final String? taskDueDate;
  final String? sourceEventId;
}

/// One classified task item in a factual close, with its as-of-close status.
final class ClassifiedCloseItem {
  const ClassifiedCloseItem({
    required this.fact,
    required this.status,
    required this.carried,
  });

  final CloseTaskFact fact;
  final CloseTaskStatus status;

  /// Whether this item is in the labeled carried-forward subset. Carried items
  /// are always a subset of missed and are never double-counted.
  final bool carried;
}

/// The factual, policy-independent task counts of a close.
final class CloseTaskCounts {
  const CloseTaskCounts({
    required this.eligible,
    required this.completed,
    required this.missed,
    required this.carried,
    required this.items,
    required this.eligibleRootHash,
    required this.completedRootHash,
  });

  final int eligible;
  final int completed;
  final int missed;
  final int carried;
  final List<ClassifiedCloseItem> items;
  final String eligibleRootHash;
  final String completedRootHash;
}

/// Pure planner policies (R-PLAN-001, R-PLAN-003, R-HOME-004).
///
/// These functions contain no I/O and no clock/timezone dependency: callers
/// resolve the planning-day boundary and pass in already-observed facts. This
/// keeps period-key derivation, the "missed" definition, and the factual-close
/// counts reproducible on every device and run.
abstract final class PlannerPolicies {
  /// The day period key: an ISO `YYYY-MM-DD` value.
  static String dayKey(LocalDate date) => date.iso;

  /// The month period key: an ISO `YYYY-MM` value.
  static String monthKey(LocalDate date) =>
      '${_pad(date.year, 4)}-${_pad(date.month, 2)}';

  /// The ISO-8601 week period key `YYYY-Www` (weeks start Monday, week 1 is the
  /// week containing the year's first Thursday).
  ///
  /// [weekStart] is accepted for future locale week-start configuration
  /// (R-GEN-004) but the persisted key uses the stable ISO-8601 week so the
  /// same physical week always maps to one record regardless of display
  /// preference.
  static String weekKey(LocalDate date, {int weekStart = 1}) {
    // ISO week: the Thursday of the current week decides both the week-year
    // and the week number (week 1 is the week containing the first Thursday).
    final int isoWeekday = date.weekday; // Mon=1..Sun=7
    final LocalDate thursday = date.addDays(4 - isoWeekday);
    final int weekYear = thursday.year;
    final int week = ((_dayOfYear(thursday) - 1) ~/ 7) + 1;
    return '${_pad(weekYear, 4)}-W${_pad(week, 2)}';
  }

  /// Derives the period key for [kind] from a planning [date].
  static String keyFor(PlanningPeriodKind kind, LocalDate date) {
    switch (kind) {
      case PlanningPeriodKind.day:
        return dayKey(date);
      case PlanningPeriodKind.week:
        return weekKey(date);
      case PlanningPeriodKind.month:
        return monthKey(date);
    }
  }

  /// Computes the factual, policy-independent task counts of a close.
  ///
  /// The eligible set is the union of planned and due tasks, excluding tasks
  /// cancelled before close (R-HOME-004). Completed is eligible tasks with a
  /// completion at or before the factual close. "Missed" is an eligible planned
  /// task still incomplete at the planning-day boundary (R-PLAN-003).
  ///
  /// [carriedEntityIds] is the labeled carried-forward subset selected during
  /// preview; every carried id must be a missed id, and carried is never
  /// counted as a second, independent outcome (R-PLAN-003). A carried id that
  /// is not missed is rejected.
  static CloseTaskCounts computeTaskClose(
    List<CloseTaskFact> facts, {
    Set<String> carriedEntityIds = const <String>{},
  }) {
    final List<ClassifiedCloseItem> items = <ClassifiedCloseItem>[];
    final List<String> eligibleTokens = <String>[];
    final List<String> completedTokens = <String>[];
    final Set<String> missedIds = <String>{};
    int eligible = 0;
    int completed = 0;
    int missed = 0;

    for (final CloseTaskFact fact in facts) {
      if (fact.cancelledBeforeClose) {
        items.add(
          ClassifiedCloseItem(
            fact: fact,
            status: CloseTaskStatus.cancelled,
            carried: false,
          ),
        );
        continue;
      }
      final bool isEligible = fact.isPlanned || fact.isDue;
      if (!isEligible) {
        // Not planned and not due: not part of this period's eligible set.
        items.add(
          ClassifiedCloseItem(
            fact: fact,
            status: CloseTaskStatus.incomplete,
            carried: false,
          ),
        );
        continue;
      }
      eligible += 1;
      eligibleTokens.add(fact.entityId);
      if (fact.completedAtOrBeforeBoundary) {
        completed += 1;
        completedTokens.add(fact.entityId);
        items.add(
          ClassifiedCloseItem(
            fact: fact,
            status: CloseTaskStatus.completed,
            carried: false,
          ),
        );
        continue;
      }
      // Eligible and incomplete at the boundary.
      if (fact.isPlanned) {
        missed += 1;
        missedIds.add(fact.entityId);
      }
    }

    // Validate the carried subset before labeling.
    for (final String carriedId in carriedEntityIds) {
      if (!missedIds.contains(carriedId)) {
        throw FormatException(
          'Carried-forward id "$carriedId" is not a missed planned task.',
        );
      }
    }

    // Second pass to label missed/carried on the incomplete-planned items.
    for (final CloseTaskFact fact in facts) {
      if (fact.cancelledBeforeClose) {
        continue;
      }
      final bool isEligible = fact.isPlanned || fact.isDue;
      if (!isEligible || fact.completedAtOrBeforeBoundary) {
        continue;
      }
      if (fact.isPlanned) {
        items.add(
          ClassifiedCloseItem(
            fact: fact,
            status: CloseTaskStatus.missed,
            carried: carriedEntityIds.contains(fact.entityId),
          ),
        );
      } else {
        items.add(
          ClassifiedCloseItem(
            fact: fact,
            status: CloseTaskStatus.incomplete,
            carried: false,
          ),
        );
      }
    }

    return CloseTaskCounts(
      eligible: eligible,
      completed: completed,
      missed: missed,
      carried: carriedEntityIds.length,
      items: items,
      eligibleRootHash: rootHash(eligibleTokens),
      completedRootHash: rootHash(completedTokens),
    );
  }

  /// A deterministic order-independent root hash over a set of [tokens].
  ///
  /// Tokens are de-duplicated and sorted before hashing so the same set always
  /// produces the same digest regardless of observation order. The digest is a
  /// 64-bit FNV-1a rendered as zero-padded hex — a reproducibility fingerprint,
  /// not a security primitive.
  static String rootHash(Iterable<String> tokens) {
    final List<String> sorted = tokens.toSet().toList()..sort();
    const int fnvOffset = 0xcbf29ce484222325;
    const int fnvPrime = 0x100000001b3;
    int hash = fnvOffset;
    for (final String token in sorted) {
      for (final int unit in token.codeUnits) {
        hash = (hash ^ unit) * fnvPrime;
        hash &= 0xffffffffffffffff;
      }
      // Separator prevents ["ab","c"] and ["a","bc"] from colliding.
      hash = (hash ^ 0x1f) * fnvPrime;
      hash &= 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static int _dayOfYear(LocalDate date) {
    final LocalDate firstOfYear = LocalDate(date.year, 1, 1);
    int days = 0;
    LocalDate cursor = firstOfYear;
    while (cursor < date) {
      cursor = cursor.addDays(1);
      days += 1;
    }
    return days + 1;
  }

  static String _pad(int value, int width) =>
      value.toString().padLeft(width, '0');
}
