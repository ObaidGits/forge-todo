import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/habits/domain/habit.dart';
import 'package:forge/features/habits/domain/habit_schedule.dart';
import 'package:forge/features/habits/domain/habit_schedule_version.dart';
import 'package:forge/features/habits/domain/habit_target.dart';

/// Explicit mapping between habit Drift rows and immutable domain aggregates
/// (design.md "Data Models").
abstract final class HabitMapper {
  static Habit habitFromRow(HabitRow row) => Habit(
    id: HabitId(row.id),
    lifeAreaId: LifeAreaId(row.lifeAreaId),
    title: row.title,
    currentScheduleVersionId: row.currentScheduleVersionId,
    rank: row.rank,
    status: HabitStatus.fromWire(row.status),
    revision: row.revision,
    createdAtUtc: row.createdAtUtc,
    updatedAtUtc: row.updatedAtUtc,
    pausedAtUtc: row.pausedAtUtc,
    deletedAtUtc: row.deletedAtUtc,
  );

  static HabitsCompanion habitToInsert(
    Habit habit, {
    required String profileId,
  }) => HabitsCompanion.insert(
    id: habit.id.value,
    profileId: profileId,
    lifeAreaId: habit.lifeAreaId.value,
    title: habit.title,
    currentScheduleVersionId: habit.currentScheduleVersionId,
    status: habit.status.wire,
    pausedAtUtc: Value<int?>(habit.pausedAtUtc),
    rank: habit.rank,
    revision: Value<int>(habit.revision),
    createdAtUtc: habit.createdAtUtc,
    updatedAtUtc: habit.updatedAtUtc,
    deletedAtUtc: Value<int?>(habit.deletedAtUtc),
  );

  static HabitScheduleVersion versionFromRow(HabitScheduleRow row) {
    return HabitScheduleVersion(
      id: row.id,
      habitId: row.habitId,
      version: row.version,
      effectiveOccurrenceKey: LocalDate.parse(row.effectiveOccurrenceKey),
      predecessorId: row.predecessorId,
      closedAtOccurrenceKey: row.closedAtOccurrenceKey == null
          ? null
          : LocalDate.parse(row.closedAtOccurrenceKey!),
      ruleVersion: row.ruleVersion,
      rule: HabitScheduleRule(
        frequency: HabitFrequency.fromWire(row.frequency),
        scheduleKind: HabitScheduleKind.fromWire(row.scheduleKind),
        start: LocalDate.parse(row.startDate),
        timezoneId: row.timezoneId,
        interval: row.interval,
        weekStart: row.weekStart,
        weekdays: _decodeInts(row.weekdays),
        monthDays: _decodeInts(row.monthDays),
      ),
      target: _targetFromRow(row),
    );
  }

  static HabitSchedulesCompanion versionToInsert(
    HabitScheduleVersion version, {
    required String profileId,
    required int nowUtc,
  }) {
    final HabitScheduleRule rule = version.rule;
    final HabitTarget target = version.target;
    return HabitSchedulesCompanion.insert(
      id: version.id,
      profileId: profileId,
      habitId: version.habitId,
      version: version.version,
      predecessorId: Value<String?>(version.predecessorId),
      effectiveOccurrenceKey: version.effectiveOccurrenceKey.iso,
      closedAtOccurrenceKey: Value<String?>(version.closedAtOccurrenceKey?.iso),
      frequency: rule.frequency.wire,
      scheduleKind: rule.scheduleKind.wire,
      interval: Value<int>(rule.interval),
      weekdays: Value<String?>(_encodeInts(rule.weekdays)),
      monthDays: Value<String?>(_encodeInts(rule.monthDays)),
      weekStart: Value<int>(rule.weekStart),
      timezoneId: rule.timezoneId,
      startDate: rule.start.iso,
      targetKind: target.kind.wire,
      targetValue: Value<int?>(target.targetValue),
      unit: Value<String?>(target.unit),
      displayUnit: Value<String?>(target.displayUnit),
      ruleVersion: Value<int>(version.ruleVersion),
      createdAtUtc: nowUtc,
      updatedAtUtc: nowUtc,
    );
  }

  static HabitTarget _targetFromRow(HabitScheduleRow row) {
    final HabitTargetKind kind = HabitTargetKind.fromWire(row.targetKind);
    switch (kind) {
      case HabitTargetKind.boolean:
        return HabitTarget.boolean();
      case HabitTargetKind.abstinence:
        return HabitTarget.abstinence();
      case HabitTargetKind.count:
        return HabitTarget.count(row.targetValue!);
      case HabitTargetKind.duration:
        return HabitTarget.duration(
          targetSeconds: row.targetValue!,
          displayUnit: row.displayUnit!,
        );
      case HabitTargetKind.quantity:
        return HabitTarget.quantity(
          targetValue: row.targetValue!,
          unit: row.unit!,
        );
    }
  }

  static Set<int> _decodeInts(String? csv) {
    if (csv == null || csv.isEmpty) {
      return const <int>{};
    }
    return csv.split(',').map(int.parse).toSet();
  }

  static String? _encodeInts(Set<int> values) {
    if (values.isEmpty) {
      return null;
    }
    final List<int> ordered = values.toList()..sort();
    return ordered.join(',');
  }
}
