import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/goal_progress.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';
import 'package:forge/features/home/application/home_content.dart';
import 'package:forge/features/learning/domain/learning_policies.dart';
import 'package:forge/features/learning/domain/learning_progress_mode.dart';
import 'package:forge/features/learning/domain/learning_resource_type.dart';
import 'package:forge/features/learning/domain/learning_statistics.dart';

import 'wave5_integration_support.dart';

/// Zero-data behaviour across the Wave 5 surfaces (R-GOAL-004, R-LEARN-004,
/// R-LEARN-005, R-HOME-001). Empty inputs must resolve to an honest
/// "not started / no computable progress / no data" state — never a misleading
/// 0% and never a crash.
///
/// **Validates: Requirements R-GOAL-004, R-LEARN-004, R-LEARN-005, R-HOME-001**
void main() {
  late Wave5IntegrationHarness h;

  setUp(() async {
    h = await Wave5IntegrationHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  int us(DateTime t) => t.microsecondsSinceEpoch;

  group('goal / roadmap derived progress', () {
    test(
      'a goal with no roadmap yields no computable progress, not 0%',
      () async {
        final String goalId = await h.createGoal('Learn Rust', seed: 'g');
        final GoalProgress progress = await h.roadmapReads.deriveGoalProgress(
          h.profileId,
          GoalId(goalId),
        );
        expect(progress.isComputable, isFalse);
        expect(progress.value, isNull);
        expect(progress.eligibleCount, 0);
        expect(progress.totalWeight, 0);
      },
    );

    test('a roadmap with no topics yields no computable progress', () async {
      final String goalId = await h.createGoal('Learn Rust', seed: 'g');
      final String roadmapId = await h.createRoadmap(goalId, seed: 'rm');
      await h.addSection(roadmapId, seed: 'sec'); // empty section only
      final GoalProgress progress = await h.roadmapReads.deriveGoalProgress(
        h.profileId,
        GoalId(goalId),
      );
      expect(progress.isComputable, isFalse);
      expect(progress.value, isNull);
    });

    test('a roadmap whose only topics are archived/cancelled has no eligible '
        'leaves and yields no computable progress', () async {
      final String goalId = await h.createGoal('Learn Rust', seed: 'g');
      final String roadmapId = await h.createRoadmap(goalId, seed: 'rm');
      final String sectionId = await h.addSection(roadmapId, seed: 'sec');
      final String a = await h.addTopic(sectionId, 'A', seed: 'ta');
      final String b = await h.addTopic(sectionId, 'B', seed: 'tb');
      await h.roadmaps.setTopicStatus(
        commandId: h.nextCommandId('sa'),
        profileId: h.profileId,
        topicId: RoadmapTopicId(a),
        status: RoadmapTopicStatus.archived,
      );
      await h.roadmaps.setTopicStatus(
        commandId: h.nextCommandId('sb'),
        profileId: h.profileId,
        topicId: RoadmapTopicId(b),
        status: RoadmapTopicStatus.cancelled,
      );

      final GoalProgress progress = await h.roadmapReads.deriveGoalProgress(
        h.profileId,
        GoalId(goalId),
      );
      expect(progress.eligibleCount, 0);
      expect(progress.isComputable, isFalse);
      expect(progress.value, isNull);
    });
  });

  group('learning progress and statistics', () {
    test('a resource with no eligible items is not started, not 0%', () async {
      final String resource = await h.createResource('Empty course', seed: 'r');
      final progress = await h.learningReads.progressOf(
        h.profileId,
        LearningResourceId(resource),
      );
      expect(progress.isStarted, isFalse);
      expect(progress.eligibleCount, 0);
      expect(progress.mode, LearningProgressMode.derived);
    });

    test(
      'resume on a resource with no items and no history is not-started',
      () async {
        final String resource = await h.createResource('Empty', seed: 'r');
        final ResumePoint resume = await h.learningReads.resumePoint(
          h.profileId,
          LearningResourceId(resource),
        );
        expect(resume.itemId, isNull);
      },
    );

    test(
      'statistics with no study sessions report zero, not a crash',
      () async {
        // A resource exists but was never studied.
        await h.createResource(
          'Unread',
          type: LearningResourceType.article,
          seed: 'r',
        );
        final LearningStatistics stats = await h.learningReads.statistics(
          h.profileId,
          rangeStartUtc: us(DateTime.utc(2024, 6, 1)),
          rangeEndUtc: us(DateTime.utc(2024, 6, 2)),
        );
        expect(stats.studiedDurationSec, 0);
        expect(stats.sessionCount, 0);
        expect(stats.completedItems, 0);
      },
    );

    test(
      'with no learning data at all statistics and Today are empty',
      () async {
        final LearningStatistics stats = await h.learningReads.statistics(
          h.profileId,
          rangeStartUtc: us(DateTime.utc(2024, 6, 1)),
          rangeEndUtc: us(DateTime.utc(2024, 6, 2)),
        );
        expect(stats.studiedDurationSec, 0);
        expect(stats.sessionCount, 0);

        final HomeTodayContent content = await h.homeQuery.today(
          profileId: h.profileId,
          currentPlanningDate: '2024-06-15',
          dayStartUtcMicros: us(DateTime.utc(2024, 6, 15)),
          nowUtcMicros: us(DateTime.utc(2024, 6, 15, 9)),
        );
        expect(content.studyRecommendation, isNull);
      },
    );
  });
}
