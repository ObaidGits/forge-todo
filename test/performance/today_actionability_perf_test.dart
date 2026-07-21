import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/home/application/home_content.dart';
import 'package:forge/features/tasks/domain/task_due.dart';

import '../database/home/home_test_support.dart';

/// In-process performance guard for Today actionability (NFR-PERF-006) and the
/// search/query latency budget family (NFR-PERF-003).
///
/// NFR-PERF-006 requires Today to be actionable ≤1.5 s cold and ≤300 ms warm at
/// the *reference profile* — an authoritative campaign that runs a packaged
/// build against the versioned benchmark profile (tool/probes/benchmark_profile
/// + docs/evidence/BENCHMARK-PROFILE.md) on ratified hardware with the external
/// 1×/2× corpora. That campaign is external evidence and cannot run in a unit
/// harness.
///
/// This guard is the automated regression tripwire that complements it: it
/// builds the real Home/Today projection from a Drift-backed corpus and asserts
/// the query stays comfortably inside the warm budget, so a query-plan or
/// materialization regression fails fast in CI rather than only surfacing in
/// the periodic reference campaign. It never weakens or substitutes for the
/// reference-profile requirement.
///
/// **Validates: Requirements R-HOME-001, NFR-PERF-006, NFR-PERF-003**
void main() {
  late HomeHarness h;

  setUp(() async {
    h = await HomeHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  // A representative Today-relevant corpus: overdue, due-today, scheduled,
  // future and completed tasks so the query exercises every bucket and its
  // ordering. Kept modest so the guard runs fast in CI while still catching a
  // full-scan / unbounded-materialization regression.
  const int perBucket = 150;

  Future<void> seedCorpus() async {
    for (int i = 0; i < perBucket; i++) {
      await h.createTask(
        seed: 'od-$i',
        title: 'Overdue $i',
        due: TaskDue.onDate('2024-06-10'),
      );
      await h.createTask(
        seed: 'td-$i',
        title: 'Today $i',
        due: TaskDue.onDate('2024-06-15'),
      );
      await h.createTask(
        seed: 'fut-$i',
        title: 'Future $i',
        due: TaskDue.onDate('2024-07-20'),
      );
      final String done = await h.createTask(
        seed: 'dn-$i',
        title: 'Done $i',
        due: TaskDue.onDate('2024-06-15'),
      );
      await h.completeTask(seed: 'dn-c-$i', taskId: done);
    }
  }

  Future<HomeTodayContent> today() => h.homeQuery.today(
    profileId: h.profileId,
    currentPlanningDate: h.planningDate,
    dayStartUtcMicros: h.dayStartUtcMicros,
    nowUtcMicros: h.nowUtcMicros,
  );

  test('[TEST-PERF-TODAY-001][MVP][TASK-4.8][R-HOME-001,NFR-PERF-006] the warm '
      'Today projection stays within the actionable budget at a representative '
      'local scale', () async {
    await seedCorpus();
    expect(await h.tasks.scalar('SELECT COUNT(*) FROM tasks'), perBucket * 4);

    // Warm the page cache and prepared statements.
    for (int i = 0; i < 10; i++) {
      await today();
    }

    const int samples = 60;
    final List<double> millis = <double>[];
    for (int i = 0; i < samples; i++) {
      final Stopwatch sw = Stopwatch()..start();
      final HomeTodayContent content = await today();
      sw.stop();
      // The projection is genuinely actionable: buckets are populated and
      // bounded, not a lazy handle.
      expect(content.agenda.overdue, isNotEmpty);
      expect(content.agenda.dueToday, isNotEmpty);
      millis.add(sw.elapsedMicroseconds / 1000.0);
    }

    millis.sort();
    final double p95 =
        millis[(millis.length * 0.95).floor().clamp(0, millis.length - 1)];
    // Warm reference budget is 300 ms end-to-end including render; the query
    // component measured here has generous headroom. This asserts we have not
    // regressed into a scan/unbounded materialization.
    expect(
      p95,
      lessThan(300.0),
      reason:
          'warm Today query p95 = ${p95.toStringAsFixed(2)} ms '
          'exceeds the 300 ms warm actionability budget',
    );
  });
}
