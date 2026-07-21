import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/home/application/home_content.dart';
import 'package:forge/features/search/domain/search_document.dart';
import 'package:forge/features/tasks/domain/task_due.dart';

import 'wave6_home_integration_support.dart';

/// Real Drift-backed Wave 6 Home integration: tasks + habits + study + focus
/// composed onto Today, plus unified search across the release-present types.
///
/// **Validates: Requirements R-HOME-001, R-HOME-002, R-HOME-003, R-HOME-005,
/// R-SEARCH-001**
///
/// Evidence: [TEST-DB-HOME-WAVE6][MVP][TASK-7.5]
void main() {
  late Wave6HomeHarness h;

  setUp(() async {
    h = await Wave6HomeHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  group('Today aggregates habits, study, and focus (R-HOME-001)', () {
    test(
      'surfaces the habit checklist, study recommendation, and focus slot',
      () async {
        await h.createTask('Standup', due: TaskDue.onDate('2024-06-15'));
        final HabitId habit = await h.createDailyHabit(
          'Meditate',
          seed: 'habit-med',
        );
        await h.createResumableResource('Algorithms');
        final String sessionId = await h.startFocus(seed: 'focus-1');

        final HomeTodayContent content = await h.loadToday();

        // Habit checklist (R-HOME-001, R-HABIT-003).
        expect(content.habitOccurrences, hasLength(1));
        final HabitOccurrenceSlot slot = content.habitOccurrences.single;
        expect(slot.habitId, habit.value);
        expect(slot.title, 'Meditate');
        expect(slot.statusWire, 'open');

        // Study resume recommendation (R-HOME-001, R-LEARN-003).
        expect(content.studyRecommendation, isNotNull);
        expect(content.studyRecommendation!.title, 'Algorithms');
        expect(content.studyRecommendation!.resumeItemTitle, 'Chapter 1');

        // Active focus session (R-HOME-001, R-FOCUS-003).
        expect(content.focus, isNotNull);
        expect(content.focus!.sessionId, sessionId);
        expect(content.focus!.isRunning, isTrue);

        // A habit consistency ring joins the tasks ring (R-HOME-001,
        // R-HABIT-007).
        final Iterable<String> ringIds = content.progressRings.map(
          (HomeProgressRing r) => r.id,
        );
        expect(ringIds, containsAll(<String>['tasks_today', 'habits_today']));
      },
    );

    test('the habits ring counts completed eligible occurrences', () async {
      final HabitId a = await h.createDailyHabit('Meditate', seed: 'h-a');
      await h.createDailyHabit('Stretch', seed: 'h-b');
      await h.checkInBooleanHabit(a, seed: 'ci-a');

      final HomeTodayContent content = await h.loadToday();
      final HomeProgressRing ring = content.progressRings.firstWhere(
        (HomeProgressRing r) => r.id == 'habits_today',
      );
      expect(ring.total, 2);
      expect(ring.completed, 1);
      expect(ring.hasData, isTrue);
    });
  });

  group('progressive slots collapse when empty (R-HOME-002)', () {
    test(
      'no habits/study/focus means empty slots and no rings for them',
      () async {
        await h.createTask('Standup', due: TaskDue.onDate('2024-06-15'));
        final HomeTodayContent content = await h.loadToday();
        expect(content.habitOccurrences, isEmpty);
        expect(content.studyRecommendation, isNull);
        expect(content.focus, isNull);
        expect(
          content.progressRings.map((HomeProgressRing r) => r.id),
          isNot(contains('habits_today')),
        );
      },
    );
  });

  group('inline actions commit durable local state (R-HOME-003)', () {
    test(
      'a habit check-in completes the occurrence read back from Drift',
      () async {
        final HabitId habit = await h.createDailyHabit('Meditate', seed: 'h-c');
        await h.checkInBooleanHabit(habit, seed: 'ci-c');

        final HomeTodayContent content = await h.loadToday();
        final HabitOccurrenceSlot slot = content.habitOccurrences.single;
        expect(slot.isCompleted, isTrue);
        // Durable: the occurrence row is committed to the local database.
        final int completed = await h.scalar(
          "SELECT COUNT(*) FROM habit_occurrences WHERE habit_id = ? "
          "AND status = 'completed'",
          <Object?>[habit.value],
        );
        expect(completed, 1);
      },
    );

    test(
      'starting focus opens exactly one session surfaced on Today',
      () async {
        final String sessionId = await h.startFocus(seed: 'focus-2');
        final HomeTodayContent content = await h.loadToday();
        expect(content.focus!.sessionId, sessionId);
        final int open = await h.scalar(
          "SELECT COUNT(*) FROM focus_sessions "
          "WHERE status IN ('running','paused') AND deleted_at_utc IS NULL",
        );
        expect(open, 1);
      },
    );
  });

  group('unified search indexes the release-present types (R-SEARCH-001)', () {
    test('habits and Learning Resources are findable via FTS', () async {
      await h.createDailyHabit('Meditate daily', seed: 'h-search');
      await h.createResumableResource('Algorithms', creator: 'Cormen');

      final SearchResults habitHits = await h.search.search(
        h.profileId,
        'Meditate',
      );
      expect(
        habitHits.groups.any((SearchResultGroup g) => g.entityType == 'habit'),
        isTrue,
      );

      final SearchResults resourceHits = await h.search.search(
        h.profileId,
        'Algorithms',
      );
      expect(
        resourceHits.groups.any(
          (SearchResultGroup g) => g.entityType == 'learning_resource',
        ),
        isTrue,
      );
    });

    test(
      'the habit projector indexes a habit into the unified index',
      () async {
        await h.createDailyHabit('Findme habit', seed: 'h-del');
        final SearchResults hits = await h.search.search(h.profileId, 'Findme');
        expect(hits.totalHits, greaterThan(0));
        expect(
          hits.groups.any((SearchResultGroup g) => g.entityType == 'habit'),
          isTrue,
        );
      },
    );
  });
}
