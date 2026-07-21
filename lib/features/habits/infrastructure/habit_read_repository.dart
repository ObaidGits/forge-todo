import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/features/habits/domain/habit_metric_policy.dart';
import 'package:forge/features/habits/domain/habit_occurrence_status.dart';

/// Read-side projections for habit metrics (R-HABIT-004, R-HABIT-007).
///
/// The read repository reads the active local generation directly (it is not
/// transaction-scoped) and maps the occurrence projection rows into
/// [HabitPeriodOutcome] values consumed by the pure [HabitMetricPolicyV1]. A
/// paused occurrence maps to [HabitPeriodOutcome.paused] regardless of its
/// stored status so it is ignored by both metrics.
final class HabitReadRepository {
  HabitReadRepository(this.db);

  final ForgeSchemaDatabase db;

  /// The key-ordered outcomes for [habitId] whose anchor falls in the inclusive
  /// `[fromIso, toIso]` local-date window.
  Future<List<HabitPeriodOutcome>> outcomes(
    String profileId,
    String habitId, {
    required String fromIso,
    required String toIso,
  }) async {
    final List<HabitOccurrenceRow> rows =
        await (db.select(db.habitOccurrences)
              ..where(
                (HabitOccurrences o) =>
                    o.profileId.equals(profileId) &
                    o.habitId.equals(habitId) &
                    o.anchorDate.isBiggerOrEqualValue(fromIso) &
                    o.anchorDate.isSmallerOrEqualValue(toIso),
              )
              ..orderBy(<OrderClauseGenerator<HabitOccurrences>>[
                (HabitOccurrences o) => OrderingTerm.asc(o.anchorDate),
                (HabitOccurrences o) => OrderingTerm.asc(o.occurrenceKey),
              ]))
            .get();
    return rows.map(_toOutcome).toList(growable: false);
  }

  /// The current streak for [habitId] over the given window under metric
  /// policy v1.
  Future<int> currentStreak(
    String profileId,
    String habitId, {
    required String fromIso,
    required String toIso,
  }) async {
    final List<HabitPeriodOutcome> outcomeList = await outcomes(
      profileId,
      habitId,
      fromIso: fromIso,
      toIso: toIso,
    );
    return HabitMetricPolicyV1.currentStreak(outcomeList);
  }

  /// Consistency for [habitId] over the given window under metric policy v1.
  Future<HabitConsistency> consistency(
    String profileId,
    String habitId, {
    required String fromIso,
    required String toIso,
  }) async {
    final List<HabitPeriodOutcome> outcomeList = await outcomes(
      profileId,
      habitId,
      fromIso: fromIso,
      toIso: toIso,
    );
    return HabitMetricPolicyV1.consistency(outcomeList);
  }

  HabitPeriodOutcome _toOutcome(HabitOccurrenceRow row) {
    if (row.isPaused) {
      return HabitPeriodOutcome.paused;
    }
    switch (HabitOccurrenceStatus.fromWire(row.status)) {
      case HabitOccurrenceStatus.completed:
        return HabitPeriodOutcome.completed;
      case HabitOccurrenceStatus.missed:
        return HabitPeriodOutcome.missed;
      case HabitOccurrenceStatus.skipped:
        return HabitPeriodOutcome.skipped;
      case HabitOccurrenceStatus.open:
        return HabitPeriodOutcome.open;
    }
  }
}
