import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/tasks/domain/task.dart';
import 'package:forge/features/tasks/domain/task_repository.dart';
import 'package:forge/features/tasks/domain/task_status.dart';

import '../database/tasks/task_test_support.dart';

/// In-process performance guard for large task lists (R-TASK-002, R-TASK-008,
/// NFR-PERF-003, NFR-PERF-004).
///
/// The authoritative common-query budget (p95 ≤100 ms at reference scale with
/// 100,000 tasks, measured on a 50-row keyset page) is an external
/// reference-profile campaign (tool/probes/benchmark_profile +
/// docs/evidence/BENCHMARK-PROFILE.md). That campaign is external evidence and
/// cannot run in a unit harness.
///
/// This guard is the automated regression tripwire that complements it and
/// asserts the two NFR-PERF-004 invariants a list read must uphold at any
/// corpus size:
///
///  * **Bounded materialization** — a limited query returns *exactly* the limit
///    and never materializes the whole corpus, regardless of how many rows
///    match. This is the guarantee that prevents an unbounded list from
///    stalling the UI isolate.
///  * **Stable ordering** — the first page is a deterministic prefix of the
///    fully ordered list, so paging is stable (the prerequisite for keyset
///    pagination).
///
/// It also asserts the bounded query stays well inside a generous latency
/// tripwire. It never weakens or substitutes for the reference-profile
/// requirement.
///
/// **Validates: Requirements NFR-PERF-004, NFR-PERF-003**
void main() {
  late TaskHarness h;

  setUp(() async {
    h = await TaskHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  // A large-but-CI-friendly corpus. Inserted directly (not through the command
  // bus) so seeding is fast; the read path under test is unchanged.
  const int corpus = 5000;
  const int pageSize = 50;

  Future<void> seed() async {
    await h.db.transaction(() async {
      for (int i = 0; i < corpus; i += 1) {
        // Zero-padded rank so ORDER BY rank ASC is a stable total order.
        final String rank = 'r${i.toString().padLeft(7, '0')}';
        await h.db.customStatement(
          'INSERT INTO tasks '
          '(id, profile_id, life_area_id, title, status, priority, rank, '
          'revision, created_at_utc, updated_at_utc) '
          "VALUES (?, ?, ?, ?, 'open', 'none', ?, 1, 0, 0)",
          <Object?>[
            't$i',
            h.profileId.value,
            h.lifeAreaId.value,
            'Task $i',
            rank,
          ],
        );
      }
    });
  }

  Future<List<Task>> page({int? limit}) => h.reads.query(
    h.profileId,
    TaskQuery(
      lifeAreaId: h.lifeAreaId,
      statuses: const <TaskStatus>{TaskStatus.open, TaskStatus.inProgress},
      limit: limit,
    ),
  );

  test(
    '[TEST-PERF-LIST-PAGINATION-001][MVP][TASK-8.4][NFR-PERF-004] a limited '
    'query materializes exactly the page size regardless of corpus size',
    () async {
      await seed();
      expect(await h.scalar('SELECT COUNT(*) FROM tasks'), corpus);

      final List<Task> firstPage = await page(limit: pageSize);
      // Bounded materialization: the page is exactly the limit even though
      // `corpus` rows match — the read never inflates to the whole table.
      expect(firstPage, hasLength(pageSize));

      // The unbounded query does return every matching row, proving the limit
      // (not a filter) is what bounds the page.
      final List<Task> everything = await page();
      expect(everything, hasLength(corpus));

      // Stable ordering: the bounded page is the deterministic prefix of the
      // fully ordered list, so paging never overlaps or skips.
      final List<String> pageIds = firstPage
          .map((Task t) => t.id.value)
          .toList(growable: false);
      final List<String> prefixIds = everything
          .take(pageSize)
          .map((Task t) => t.id.value)
          .toList(growable: false);
      expect(pageIds, prefixIds);
    },
  );

  test(
    '[TEST-PERF-LIST-PAGINATION-002][MVP][TASK-8.4][NFR-PERF-003] the bounded '
    'first page stays well inside the common-query tripwire',
    () async {
      await seed();

      // Warm the page cache and prepared statement.
      for (int i = 0; i < 10; i += 1) {
        await page(limit: pageSize);
      }

      const int samples = 60;
      final List<double> millis = <double>[];
      for (int i = 0; i < samples; i += 1) {
        final Stopwatch sw = Stopwatch()..start();
        final List<Task> rows = await page(limit: pageSize);
        sw.stop();
        expect(rows, hasLength(pageSize));
        millis.add(sw.elapsedMicroseconds / 1000.0);
      }
      millis.sort();
      final double p95 =
          millis[(millis.length * 0.95).floor().clamp(0, millis.length - 1)];
      // Generous headroom over the 100 ms common-query budget; a bounded page
      // over a few thousand rows is milliseconds, so this only trips on a real
      // scan / unbounded-materialization regression.
      expect(
        p95,
        lessThan(100.0),
        reason:
            'bounded task page p95 = ${p95.toStringAsFixed(2)} ms exceeds the '
            '100 ms common-query budget',
      );
    },
  );

  test(
    '[TEST-PERF-LIST-PAGINATION-003][MVP][TASK-8.4][NFR-PERF-004] the ordered '
    'keyset page uses the area+rank index instead of scanning the table',
    () async {
      await seed();
      final List<QueryRow> plan = await h.db
          .customSelect(
            'EXPLAIN QUERY PLAN '
            'SELECT * FROM tasks '
            'WHERE profile_id = ? AND life_area_id = ? '
            "AND deleted_at_utc IS NULL AND status IN ('open', 'in_progress') "
            'ORDER BY rank ASC, id ASC LIMIT ?',
            variables: <Variable<Object>>[
              Variable<String>(h.profileId.value),
              Variable<String>(h.lifeAreaId.value),
              const Variable<int>(pageSize),
            ],
          )
          .get();
      final String detail = plan
          .map((QueryRow r) => r.data['detail'] as String)
          .join(' | ')
          .toLowerCase();
      // The `(profile_id, life_area_id, ...)` equality is served by an index,
      // so the plan performs an indexed SEARCH rather than a full-table SCAN.
      // (Which specific index the planner picks is a cost decision; the
      // invariant is that it is not an unindexed scan of the whole table.)
      expect(detail, contains('search'));
      expect(detail, isNot(contains('scan tasks')));
    },
  );
}
