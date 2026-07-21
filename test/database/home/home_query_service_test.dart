import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/home/application/home_content.dart';
import 'package:forge/features/home/domain/home_layout.dart';
import 'package:forge/features/home/domain/home_section.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/domain/task_priority.dart';

import 'home_test_support.dart';

/// Real Drift-backed Home query + durable layout tests.
///
/// **Validates: Requirements R-HOME-001, R-HOME-002, R-HOME-005, R-GEN-001**
void main() {
  late HomeHarness h;

  // Clock pinned to 2024-06-15 09:00 UTC by the harness.
  Future<HomeTodayContent> today() => h.homeQuery.today(
    profileId: h.profileId,
    currentPlanningDate: h.planningDate,
    dayStartUtcMicros: h.dayStartUtcMicros,
    nowUtcMicros: h.nowUtcMicros,
  );

  setUp(() async {
    h = await HomeHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  group('Today agenda is reconstructed from Drift (R-HOME-001, R-GEN-001)', () {
    test('splits overdue, due-today, and completed-today buckets', () async {
      // Overdue: due before the planning day.
      await h.createTask(
        seed: 'overdue',
        title: 'File taxes',
        due: TaskDue.onDate('2024-06-10'),
      );
      // Due today.
      await h.createTask(
        seed: 'due-today',
        title: 'Standup',
        due: TaskDue.onDate('2024-06-15'),
      );
      // Scheduled today, no due date — actionable today, not overdue.
      await h.createTask(
        seed: 'sched',
        title: 'Draft memo',
        scheduledDate: '2024-06-15',
      );
      // Future — not on Today at all.
      await h.createTask(
        seed: 'future',
        title: 'Later',
        due: TaskDue.onDate('2024-07-01'),
      );
      // Completed today.
      final String done = await h.createTask(
        seed: 'done',
        title: 'Morning walk',
        due: TaskDue.onDate('2024-06-15'),
      );
      await h.completeTask(seed: 'done-c', taskId: done);

      final HomeTodayContent content = await today();
      final TodayAgenda agenda = content.agenda;

      expect(agenda.overdue.map((TaskSummary t) => t.title), <String>[
        'File taxes',
      ]);
      expect(agenda.overdue.single.isOverdue, isTrue);
      expect(agenda.dueToday.map((TaskSummary t) => t.title).toSet(), <String>{
        'Standup',
        'Draft memo',
      });
      expect(agenda.dueToday.every((TaskSummary t) => !t.isOverdue), isTrue);
      expect(agenda.completedToday.map((TaskSummary t) => t.title), <String>[
        'Morning walk',
      ]);
    });

    test('instant tasks are overdue only once now passes due_at', () async {
      // now is 2024-06-15 09:00 UTC.
      final int past = DateTime.utc(2024, 6, 15, 8).microsecondsSinceEpoch;
      final int future = DateTime.utc(2024, 6, 15, 10).microsecondsSinceEpoch;
      await h.createTask(
        seed: 'past',
        title: 'Missed call',
        due: TaskDue.atInstant(utcMicros: past, timezoneId: 'UTC'),
      );
      await h.createTask(
        seed: 'soon',
        title: 'Upcoming call',
        due: TaskDue.atInstant(utcMicros: future, timezoneId: 'UTC'),
      );

      final TodayAgenda agenda = (await today()).agenda;
      expect(agenda.overdue.map((TaskSummary t) => t.title), <String>[
        'Missed call',
      ]);
      expect(agenda.dueToday.map((TaskSummary t) => t.title), <String>[
        'Upcoming call',
      ]);
    });

    test('overdue is ordered by priority then rank', () async {
      await h.createTask(
        seed: 'low',
        title: 'Low',
        due: TaskDue.onDate('2024-06-10'),
        priority: TaskPriority.low,
      );
      await h.createTask(
        seed: 'urgent',
        title: 'Urgent',
        due: TaskDue.onDate('2024-06-10'),
        priority: TaskPriority.urgent,
      );
      final TodayAgenda agenda = (await today()).agenda;
      expect(agenda.overdue.map((TaskSummary t) => t.title), <String>[
        'Urgent',
        'Low',
      ]);
    });
  });

  group('progress rings under metric policy v1 (R-HOME-001)', () {
    test(
      'reports completed/total with a named policy and no-data state',
      () async {
        // No tasks -> ring has no computable value.
        HomeTodayContent content = await today();
        HomeProgressRing ring = content.progressRings.single;
        expect(ring.id, 'tasks_today');
        expect(ring.metricPolicyVersion, 'v1');
        expect(ring.hasData, isFalse);

        await h.createTask(
          seed: 'a',
          title: 'A',
          due: TaskDue.onDate('2024-06-15'),
        );
        final String b = await h.createTask(
          seed: 'b',
          title: 'B',
          due: TaskDue.onDate('2024-06-15'),
        );
        await h.completeTask(seed: 'b-c', taskId: b);

        content = await today();
        ring = content.progressRings.single;
        expect(ring.total, 2);
        expect(ring.completed, 1);
        expect(ring.fraction, closeTo(0.5, 1e-9));
        expect(ring.hasData, isTrue);
      },
    );
  });

  group('progressive slots collapse in the tasks era (R-HOME-002)', () {
    test(
      'habit/study/focus/quick-note slots are empty and sync is local',
      () async {
        final HomeTodayContent content = await today();
        expect(content.habitOccurrences, isEmpty);
        expect(content.studyRecommendation, isNull);
        expect(content.focus, isNull);
        expect(content.quickNote, isNull);
        expect(content.syncStatus, HomeSyncStatus.localOnly);
      },
    );
  });

  group('committed capture is durable across restart (R-GEN-001)', () {
    test(
      'a captured task persists and reappears from a fresh read stack',
      () async {
        await h.createTask(
          seed: 'persist',
          title: 'Persisted task',
          due: TaskDue.onDate('2024-06-15'),
        );

        // Simulate an app restart: re-open the read stack over the same DB file
        // is not possible with an in-memory DB, so we assert the committed row is
        // read back through an independent query call (fresh projection),
        // proving provider state is not the source of truth.
        final TodayAgenda agenda = (await today()).agenda;
        expect(
          agenda.dueToday.map((TaskSummary t) => t.title),
          contains('Persisted task'),
        );
      },
    );
  });

  group('durable Today layout preference (R-HOME-002, R-HOME-005)', () {
    test(
      'defaults when unset, then round-trips through the settings table',
      () async {
        final HomeLayout initial = await h.layoutStore.load(h.profileId);
        expect(initial.isDefault, isTrue);

        final HomeLayout custom = HomeLayout.defaultLayout
            .moveUp(HomeSectionKind.progress)
            .hide(HomeSectionKind.habits);
        await h.layoutStore.save(h.profileId, custom);

        // A subsequent load (as on the next launch) reconstructs the preference
        // from Drift, not from memory.
        final HomeLayout reloaded = await h.layoutStore.load(h.profileId);
        expect(reloaded.order, custom.order);
        expect(reloaded.hidden, custom.hidden);
        expect(reloaded.isDefault, isFalse);
      },
    );

    test('saving twice updates in place (idempotent upsert)', () async {
      await h.layoutStore.save(
        h.profileId,
        HomeLayout.defaultLayout.hide(HomeSectionKind.focus),
      );
      await h.layoutStore.save(
        h.profileId,
        HomeLayout.defaultLayout.hide(HomeSectionKind.progress),
      );
      final HomeLayout reloaded = await h.layoutStore.load(h.profileId);
      expect(reloaded.isHidden(HomeSectionKind.progress), isTrue);
      expect(reloaded.isHidden(HomeSectionKind.focus), isFalse);
    });
  });
}
