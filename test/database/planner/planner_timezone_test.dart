import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/time/timezone_resolver.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/core/domain/time_zone.dart';
import 'package:forge/features/planner/domain/planner_policies.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';

/// Planner period keys compose with R-GEN-004 time correctness: the planning
/// day is resolved from a trusted instant through the timezone resolver, and
/// the derived period key is timezone-free and DST-stable (R-PLAN-001,
/// R-GEN-004).
void main() {
  late TimeZoneResolver resolver;

  setUp(() {
    resolver = TimezonePackageResolver.initialized();
  });

  /// The planning day for a trusted [utcMicros] instant under [zone] and a
  /// [boundaryMinutes] planning-day boundary offset from local midnight.
  LocalDate planningDay(int utcMicros, String zone, int boundaryMinutes) {
    final int shifted = utcMicros - boundaryMinutes * 60 * 1000 * 1000;
    final LocalDateTime local = resolver.toLocal(zone, shifted);
    return local.date;
  }

  test('[TEST-DB-PLAN-TZ-DAYKEY][MVP][TASK-5.4][R-PLAN-001,R-GEN-004] '
      'the day key follows the local wall-clock day, not UTC', () {
    // 2024-06-02 04:30 UTC is still 2024-06-01 in America/Los_Angeles.
    final ZonedInstant instant = resolver.toInstant(
      'America/Los_Angeles',
      LocalDateTime(LocalDate(2024, 6, 1), LocalTime(21, 30)),
    );
    final LocalDate day = planningDay(
      instant.utcMicros,
      'America/Los_Angeles',
      0,
    );
    expect(PlannerPolicies.keyFor(PlanningPeriodKind.day, day), '2024-06-01');
  });

  test(
    '[TEST-DB-PLAN-TZ-BOUNDARY][MVP][TASK-5.4][R-PLAN-001,R-GEN-004] '
    'a custom planning-day boundary keeps early-morning work in the prior day',
    () {
      // 01:00 local with a 03:00 (180-minute) planning-day boundary belongs to
      // the previous planning day.
      final ZonedInstant instant = resolver.toInstant(
        'Europe/Berlin',
        LocalDateTime(LocalDate(2024, 6, 2), LocalTime(1, 0)),
      );
      final LocalDate day = planningDay(
        instant.utcMicros,
        'Europe/Berlin',
        180,
      );
      expect(PlannerPolicies.keyFor(PlanningPeriodKind.day, day), '2024-06-01');
    },
  );

  test('[TEST-DB-PLAN-TZ-DST-STABLE][MVP][TASK-5.4][R-GEN-004] '
      'the day key is stable across a DST spring-forward transition', () {
    // US DST spring-forward is 2024-03-10. Local noon that day resolves to a
    // single instant and the planning day remains 2024-03-10.
    final ZonedInstant instant = resolver.toInstant(
      'America/Los_Angeles',
      LocalDateTime(LocalDate(2024, 3, 10), LocalTime(12, 0)),
    );
    final LocalDate day = planningDay(
      instant.utcMicros,
      'America/Los_Angeles',
      0,
    );
    expect(day.iso, '2024-03-10');
    expect(PlannerPolicies.keyFor(PlanningPeriodKind.week, day), '2024-W10');
  });
}
