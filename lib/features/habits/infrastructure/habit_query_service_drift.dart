import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/habits/application/habit_impact_calculator.dart';
import 'package:forge/features/habits/application/habit_query_service.dart';
import 'package:forge/features/habits/domain/habit_metric_policy.dart';
import 'package:forge/features/habits/domain/habit_occurrence_engine.dart';
import 'package:forge/features/habits/domain/habit_occurrence_key.dart';
import 'package:forge/features/habits/domain/habit_schedule_version.dart';
import 'package:forge/features/habits/domain/habit_target.dart';
import 'package:forge/features/habits/infrastructure/habit_mapper.dart';

/// Read-side implementation of [HabitQueryService] over the active local Drift
/// generation (R-HOME-001, R-HABIT-004, R-HABIT-005, R-HABIT-007).
///
/// The query service reads the active local generation directly (it is not
/// transaction-scoped) and composes the pure domain policies — the occurrence
/// engine, the metric policy, and the impact calculator — so the presentation
/// surface never re-implements schedule or metric semantics. Occurrence math is
/// wall-clock only; no clock or timezone database is consulted here.
final class DriftHabitQueryService implements HabitQueryService {
  DriftHabitQueryService(this.db);

  final ForgeSchemaDatabase db;

  @override
  Future<HabitSummary?> summary({
    required ProfileId profileId,
    required HabitId habitId,
  }) async {
    final HabitRow? habit =
        await (db.select(db.habits)..where(
              (Habits h) =>
                  h.profileId.equals(profileId.value) &
                  h.id.equals(habitId.value) &
                  h.deletedAtUtc.isNull(),
            ))
            .getSingleOrNull();
    if (habit == null) {
      return null;
    }
    final HabitScheduleRow? scheduleRow =
        await (db.select(db.habitSchedules)..where(
              (HabitSchedules s) =>
                  s.profileId.equals(profileId.value) &
                  s.id.equals(habit.currentScheduleVersionId),
            ))
            .getSingleOrNull();
    final HabitTarget? target = scheduleRow == null
        ? null
        : HabitMapper.versionFromRow(scheduleRow).target;
    return HabitSummary(
      habitId: habit.id,
      title: habit.title,
      targetKindWire: target?.kind.wire ?? kHabitTargetBoolean,
      isPaused: habit.pausedAtUtc != null,
      targetValue: target?.targetValue,
      unit: target?.unit,
      displayUnit: target?.displayUnit,
    );
  }

  @override
  Future<List<HabitTodayEntry>> todayChecklist({
    required ProfileId profileId,
    required LocalDate onDate,
  }) async {
    final List<HabitRow> habits =
        await (db.select(db.habits)
              ..where(
                (Habits h) =>
                    h.profileId.equals(profileId.value) &
                    h.deletedAtUtc.isNull() &
                    h.status.equals('active'),
              )
              ..orderBy(<OrderClauseGenerator<Habits>>[
                (Habits h) => OrderingTerm.asc(h.rank),
                (Habits h) => OrderingTerm.asc(h.id),
              ]))
            .get();

    final List<HabitTodayEntry> entries = <HabitTodayEntry>[];
    for (final HabitRow habit in habits) {
      final HabitScheduleVersion? version = await _versionEffectiveAt(
        profileId.value,
        habit.id,
        onDate,
      );
      if (version == null) {
        continue;
      }
      final HabitOccurrenceKey? key = HabitOccurrenceEngine.keyFor(
        version.rule,
        onDate,
      );
      if (key == null) {
        continue; // not a scheduled occurrence on this date
      }
      final HabitOccurrenceRow? occurrence = await _occurrenceByKey(
        profileId.value,
        habit.id,
        key.value,
      );
      final bool paused =
          occurrence?.isPaused ??
          await _isAnchorPaused(profileId.value, habit.id, key.anchor);
      final HabitTarget target = version.target;
      entries.add(
        HabitTodayEntry(
          habitId: habit.id,
          title: habit.title,
          onDateIso: onDate.iso,
          occurrenceKey: key.value,
          statusWire: occurrence?.status ?? 'open',
          targetKindWire: target.kind.wire,
          normalizedTotal: occurrence?.normalizedTotal ?? 0,
          isPaused: paused,
          targetValue: target.targetValue,
          unit: target.unit,
          displayUnit: target.displayUnit,
        ),
      );
    }
    return entries;
  }

  @override
  Future<List<HabitOccurrenceView>> history({
    required ProfileId profileId,
    required HabitId habitId,
    required LocalDate from,
    required LocalDate to,
  }) async {
    final List<HabitOccurrenceRow> rows = await _occurrencesInWindow(
      profileId.value,
      habitId.value,
      from,
      to,
      descending: true,
    );
    return rows.map(_toOccurrenceView).toList(growable: false);
  }

  @override
  Future<HabitCalendarMonth> calendarMonth({
    required ProfileId profileId,
    required HabitId habitId,
    required int year,
    required int month,
  }) async {
    final LocalDate first = LocalDate(year, month, 1);
    final LocalDate last = first.lastDayOfMonth;
    final List<HabitOccurrenceRow> rows = await _occurrencesInWindow(
      profileId.value,
      habitId.value,
      first,
      last,
      descending: false,
    );
    final Map<String, HabitOccurrenceView> byDay =
        <String, HabitOccurrenceView>{};
    for (final HabitOccurrenceRow row in rows) {
      byDay[row.anchorDate] = _toOccurrenceView(row);
    }
    return HabitCalendarMonth(
      year: year,
      month: month,
      occurrencesByDayIso: byDay,
    );
  }

  @override
  Future<HabitStatistics> statistics({
    required ProfileId profileId,
    required HabitId habitId,
    required LocalDate from,
    required LocalDate to,
  }) async {
    final List<HabitPeriodOutcome> outcomes = (await _occurrencesInWindow(
      profileId.value,
      habitId.value,
      from,
      to,
      descending: false,
    )).map((HabitOccurrenceRow r) => _toOccurrenceView(r).outcome).toList();
    return HabitStatistics(
      currentStreak: HabitMetricPolicyV1.currentStreak(outcomes),
      consistency: HabitMetricPolicyV1.consistency(outcomes),
      fromIso: from.iso,
      toIso: to.iso,
    );
  }

  @override
  Future<HabitImpactPreview> impactPreview({
    required ProfileId profileId,
    required HabitId habitId,
    required LocalDate from,
    required LocalDate to,
    required LocalDate onDate,
    required HabitPreviewOutcome outcome,
  }) async {
    final List<HabitOccurrenceRow> rows = await _occurrencesInWindow(
      profileId.value,
      habitId.value,
      from,
      to,
      descending: false,
    );
    final List<HabitPeriodOutcome> before = rows
        .map((HabitOccurrenceRow r) => _toOccurrenceView(r).outcome)
        .toList();

    // Locate an existing occurrence on the target date to replace, otherwise
    // insert the backfilled occurrence at its key-ordered position.
    final String onIso = onDate.iso;
    int existingIndex = -1;
    int insertIndex = rows.length;
    for (int i = 0; i < rows.length; i++) {
      final String anchor = rows[i].anchorDate;
      if (anchor == onIso) {
        existingIndex = i;
        break;
      }
      if (anchor.compareTo(onIso) > 0) {
        insertIndex = i;
        break;
      }
    }

    final List<HabitPeriodOutcome> after = List<HabitPeriodOutcome>.of(before);
    if (existingIndex >= 0) {
      after[existingIndex] = outcome.asPeriodOutcome;
    } else {
      after.insert(insertIndex, outcome.asPeriodOutcome);
    }
    return HabitImpactCalculator.preview(before: before, after: after);
  }

  // ---- queries ------------------------------------------------------------

  Future<HabitScheduleVersion?> _versionEffectiveAt(
    String profileId,
    String habitId,
    LocalDate anchor,
  ) async {
    final HabitScheduleRow? row =
        await (db.select(db.habitSchedules)
              ..where(
                (HabitSchedules s) =>
                    s.profileId.equals(profileId) &
                    s.habitId.equals(habitId) &
                    s.effectiveOccurrenceKey.isSmallerOrEqualValue(anchor.iso) &
                    (s.closedAtOccurrenceKey.isNull() |
                        s.closedAtOccurrenceKey.isBiggerThanValue(anchor.iso)),
              )
              ..orderBy(<OrderClauseGenerator<HabitSchedules>>[
                (HabitSchedules s) => OrderingTerm.desc(s.version),
              ])
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : HabitMapper.versionFromRow(row);
  }

  Future<HabitOccurrenceRow?> _occurrenceByKey(
    String profileId,
    String habitId,
    String occurrenceKey,
  ) {
    return (db.select(db.habitOccurrences)..where(
          (HabitOccurrences o) =>
              o.profileId.equals(profileId) &
              o.habitId.equals(habitId) &
              o.occurrenceKey.equals(occurrenceKey),
        ))
        .getSingleOrNull();
  }

  Future<List<HabitOccurrenceRow>> _occurrencesInWindow(
    String profileId,
    String habitId,
    LocalDate from,
    LocalDate to, {
    required bool descending,
  }) {
    return (db.select(db.habitOccurrences)
          ..where(
            (HabitOccurrences o) =>
                o.profileId.equals(profileId) &
                o.habitId.equals(habitId) &
                o.anchorDate.isBiggerOrEqualValue(from.iso) &
                o.anchorDate.isSmallerOrEqualValue(to.iso),
          )
          ..orderBy(<OrderClauseGenerator<HabitOccurrences>>[
            (HabitOccurrences o) => descending
                ? OrderingTerm.desc(o.anchorDate)
                : OrderingTerm.asc(o.anchorDate),
            (HabitOccurrences o) => descending
                ? OrderingTerm.desc(o.occurrenceKey)
                : OrderingTerm.asc(o.occurrenceKey),
          ]))
        .get();
  }

  Future<bool> _isAnchorPaused(
    String profileId,
    String habitId,
    LocalDate anchor,
  ) async {
    final HabitPauseRow? row =
        await (db.select(db.habitPauses)
              ..where(
                (HabitPauses p) =>
                    p.profileId.equals(profileId) &
                    p.habitId.equals(habitId) &
                    p.startDate.isSmallerOrEqualValue(anchor.iso) &
                    (p.endDate.isNull() |
                        p.endDate.isBiggerOrEqualValue(anchor.iso)),
              )
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  HabitOccurrenceView _toOccurrenceView(HabitOccurrenceRow row) =>
      HabitOccurrenceView(
        occurrenceKey: row.occurrenceKey,
        anchorIso: row.anchorDate,
        statusWire: row.status,
        normalizedTotal: row.normalizedTotal,
        isPaused: row.isPaused,
      );
}
