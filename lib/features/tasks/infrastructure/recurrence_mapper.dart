import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_end.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_frequency.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_rule.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_schedule_version.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_weekday.dart';

/// Explicit mapping between the `recurrence_rules` Drift row and the immutable
/// [RecurrenceScheduleVersion] domain aggregate (design.md "Data Models").
///
/// Exceptions are not stored in the immutable rule row; they live as
/// append-only occurrence events and are folded back into the rule at read time
/// via [RecurrenceRule.withExceptions].
abstract final class RecurrenceMapper {
  /// Rebuilds a schedule version from a persisted row.
  static RecurrenceScheduleVersion versionFromRow(RecurrenceRuleRow row) {
    return RecurrenceScheduleVersion(
      id: row.id,
      seriesId: row.seriesId,
      version: row.version,
      effectiveOccurrenceKey: LocalDate.parse(row.effectiveOccurrenceKey),
      predecessorId: row.predecessorId,
      closedAtOccurrenceKey: row.closedAtOccurrenceKey == null
          ? null
          : LocalDate.parse(row.closedAtOccurrenceKey!),
      strategyVersion: row.strategyVersion,
      rule: RecurrenceRule(
        frequency: RecurrenceFrequency.fromWire(row.frequency),
        start: LocalDate.parse(row.startDate),
        timezoneId: row.timezoneId,
        interval: row.interval,
        byWeekdays: _decodeWeekdays(row.byWeekdays),
        byMonthDays: _decodeMonthDays(row.byMonthDays),
        timeOfDay: row.timeOfDaySeconds == null
            ? null
            : LocalTime.fromSecondsOfDay(row.timeOfDaySeconds!),
        end: _decodeEnd(row.countLimit, row.untilDate),
      ),
    );
  }

  /// Builds an insert companion for a schedule version owned by [taskId].
  static RecurrenceRulesCompanion toInsert(
    RecurrenceScheduleVersion version, {
    required String profileId,
    required String taskId,
    required int nowUtc,
  }) {
    final RecurrenceRule rule = version.rule;
    final RecurrenceEnd end = rule.end;
    return RecurrenceRulesCompanion.insert(
      id: version.id,
      profileId: profileId,
      taskId: taskId,
      seriesId: version.seriesId,
      version: version.version,
      predecessorId: Value<String?>(version.predecessorId),
      effectiveOccurrenceKey: version.effectiveOccurrenceKey.iso,
      closedAtOccurrenceKey: Value<String?>(version.closedAtOccurrenceKey?.iso),
      frequency: rule.frequency.wire,
      interval: Value<int>(rule.interval),
      byWeekdays: Value<String?>(_encodeWeekdays(rule.byWeekdays)),
      byMonthDays: Value<String?>(_encodeMonthDays(rule.byMonthDays)),
      countLimit: Value<int?>(end is CountLimit ? end.count : null),
      untilDate: Value<String?>(end is UntilDate ? end.date.iso : null),
      timezoneId: rule.timezoneId,
      startDate: rule.start.iso,
      timeOfDaySeconds: Value<int?>(rule.timeOfDay?.secondsOfDay),
      strategyVersion: Value<int>(version.strategyVersion),
      createdAtUtc: nowUtc,
      updatedAtUtc: nowUtc,
    );
  }

  static Set<RecurrenceWeekday> _decodeWeekdays(String? csv) {
    if (csv == null || csv.isEmpty) {
      return const <RecurrenceWeekday>{};
    }
    return csv.split(',').map(RecurrenceWeekday.fromWire).toSet();
  }

  static String? _encodeWeekdays(Set<RecurrenceWeekday> days) {
    if (days.isEmpty) {
      return null;
    }
    final List<RecurrenceWeekday> ordered = days.toList()
      ..sort((a, b) => a.isoWeekday.compareTo(b.isoWeekday));
    return ordered.map((RecurrenceWeekday d) => d.wire).join(',');
  }

  static Set<int> _decodeMonthDays(String? csv) {
    if (csv == null || csv.isEmpty) {
      return const <int>{};
    }
    return csv.split(',').map(int.parse).toSet();
  }

  static String? _encodeMonthDays(Set<int> days) {
    if (days.isEmpty) {
      return null;
    }
    final List<int> ordered = days.toList()..sort();
    return ordered.join(',');
  }

  static RecurrenceEnd _decodeEnd(int? countLimit, String? untilDate) {
    if (countLimit != null) {
      return RecurrenceEnd.count(countLimit);
    }
    if (untilDate != null) {
      return RecurrenceEnd.until(LocalDate.parse(untilDate));
    }
    return RecurrenceEnd.never;
  }
}
