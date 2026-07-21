import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/goal_progress.dart';
import 'package:forge/features/goals/domain/goal_rank.dart';
import 'package:forge/features/goals/domain/roadmap_progress.dart';
import 'package:forge/features/goals/domain/roadmap_topic.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';

/// Roadmap progress policy: topic-only weighted leaves, presentation-only
/// section aggregation, and no double counting (R-GOAL-004).
///
/// **Validates: Requirements R-GOAL-004**
void main() {
  RoadmapTopic topic({
    required String id,
    required String sectionId,
    RoadmapTopicStatus status = RoadmapTopicStatus.open,
    num? weight,
    int? deletedAtUtc,
  }) => RoadmapTopic(
    id: RoadmapTopicId(id),
    profileId: ProfileId('p1'),
    sectionId: RoadmapSectionId(sectionId),
    title: 'T$id',
    status: status,
    weight: weight,
    rank: GoalRank.initial,
    createdAtUtc: 0,
    updatedAtUtc: 0,
    deletedAtUtc: deletedAtUtc,
  );

  group('given topics as the only weighted leaves', () {
    test('then completed eligible weight divides eligible weight', () {
      final GoalProgress p = RoadmapProgressPolicy.forRoadmap(<RoadmapTopic>[
        topic(
          id: 'a',
          sectionId: 's1',
          status: RoadmapTopicStatus.completed,
          weight: 3,
        ),
        topic(id: 'b', sectionId: 's1', weight: 1),
      ]);
      expect(p.value, closeTo(3 / 4, 1e-12));
      expect(p.eligibleCount, 2);
      expect(p.totalWeight, 4);
      expect(p.completedWeight, 3);
      expect(p.formula, GoalProgressPolicy.derivedFormula);
    });

    test('then a null topic weight normalizes to 1', () {
      final GoalProgress p = RoadmapProgressPolicy.forRoadmap(<RoadmapTopic>[
        topic(id: 'a', sectionId: 's1', status: RoadmapTopicStatus.completed),
        topic(id: 'b', sectionId: 's1'),
      ]);
      expect(p.totalWeight, 2);
      expect(p.completedWeight, 1);
      expect(p.value, closeTo(0.5, 1e-12));
    });

    test('then archived and cancelled topics are excluded', () {
      final GoalProgress p = RoadmapProgressPolicy.forRoadmap(<RoadmapTopic>[
        topic(
          id: 'a',
          sectionId: 's1',
          status: RoadmapTopicStatus.completed,
          weight: 2,
        ),
        topic(
          id: 'b',
          sectionId: 's1',
          status: RoadmapTopicStatus.archived,
          weight: 99,
        ),
        topic(
          id: 'c',
          sectionId: 's1',
          status: RoadmapTopicStatus.cancelled,
          weight: 99,
        ),
      ]);
      expect(p.eligibleCount, 1);
      expect(p.totalWeight, 2);
      expect(p.value, 1.0);
    });

    test('then a soft-deleted topic is ineligible', () {
      final GoalProgress p = RoadmapProgressPolicy.forRoadmap(<RoadmapTopic>[
        topic(
          id: 'a',
          sectionId: 's1',
          status: RoadmapTopicStatus.completed,
          weight: 5,
        ),
        topic(id: 'b', sectionId: 's1', weight: 5, deletedAtUtc: 123),
      ]);
      expect(p.eligibleCount, 1);
      expect(p.value, 1.0);
    });

    test('then no topics yields no computable progress', () {
      final GoalProgress p = RoadmapProgressPolicy.forRoadmap(
        const <RoadmapTopic>[],
      );
      expect(p.value, isNull);
      expect(p.isComputable, isFalse);
    });

    test('then a zero eligible total weight yields no computable progress', () {
      final GoalProgress p = RoadmapProgressPolicy.forRoadmap(<RoadmapTopic>[
        topic(id: 'a', sectionId: 's1', weight: 0),
        topic(
          id: 'b',
          sectionId: 's1',
          status: RoadmapTopicStatus.completed,
          weight: 0,
        ),
      ]);
      expect(p.value, isNull);
      expect(p.eligibleCount, 2);
      expect(p.totalWeight, 0);
    });
  });

  group('given section aggregation (presentation only)', () {
    test('then per-section totals partition the roadmap total exactly '
        '(each topic counted once, no double count)', () {
      final List<RoadmapTopic> s1 = <RoadmapTopic>[
        topic(
          id: 'a',
          sectionId: 's1',
          status: RoadmapTopicStatus.completed,
          weight: 2,
        ),
        topic(id: 'b', sectionId: 's1', weight: 3),
      ];
      final List<RoadmapTopic> s2 = <RoadmapTopic>[
        topic(
          id: 'c',
          sectionId: 's2',
          status: RoadmapTopicStatus.completed,
          weight: 1,
        ),
        topic(
          id: 'd',
          sectionId: 's2',
          status: RoadmapTopicStatus.archived,
          weight: 99,
        ),
      ];
      final GoalProgress sec1 = RoadmapProgressPolicy.forSection(s1);
      final GoalProgress sec2 = RoadmapProgressPolicy.forSection(s2);
      final GoalProgress whole = RoadmapProgressPolicy.forRoadmap(
        <RoadmapTopic>[...s1, ...s2],
      );

      // The roadmap total is exactly the sum of the section aggregations: a
      // topic contributes to exactly one section and once to the whole.
      expect(sec1.totalWeight + sec2.totalWeight, whole.totalWeight);
      expect(
        sec1.completedWeight + sec2.completedWeight,
        whole.completedWeight,
      );
      expect(sec1.eligibleCount + sec2.eligibleCount, whole.eligibleCount);
    });
  });

  group('given randomized roadmaps when computing progress', () {
    test('[TEST-ROADMAP-PROGRESS-PROP][MVP][TASK-6.2][R-GOAL-004] '
        'section aggregations always partition the roadmap total and progress '
        'stays in 0..1', () {
      const int cases = 300;
      for (int seed = 0; seed < cases; seed += 1) {
        final Random rng = Random(0x60AD ^ seed);
        final int sections = 1 + rng.nextInt(4);
        final List<RoadmapTopic> all = <RoadmapTopic>[];
        final List<List<RoadmapTopic>> bySection = <List<RoadmapTopic>>[];
        for (int s = 0; s < sections; s += 1) {
          final List<RoadmapTopic> topics = <RoadmapTopic>[];
          final int n = rng.nextInt(5);
          for (int i = 0; i < n; i += 1) {
            final RoadmapTopicStatus status = RoadmapTopicStatus
                .values[rng.nextInt(RoadmapTopicStatus.values.length)];
            final num? weight = rng.nextInt(4) == 0 ? null : rng.nextInt(6);
            final RoadmapTopic t = topic(
              id: 's${s}t$i',
              sectionId: 's$s',
              status: status,
              weight: weight,
            );
            topics.add(t);
            all.add(t);
          }
          bySection.add(topics);
        }

        final GoalProgress whole = RoadmapProgressPolicy.forRoadmap(all);
        num sumTotal = 0;
        num sumCompleted = 0;
        int sumEligible = 0;
        for (final List<RoadmapTopic> topics in bySection) {
          final GoalProgress sec = RoadmapProgressPolicy.forSection(topics);
          sumTotal += sec.totalWeight;
          sumCompleted += sec.completedWeight;
          sumEligible += sec.eligibleCount;
        }
        expect(sumTotal, whole.totalWeight, reason: 'seed=$seed');
        expect(sumCompleted, whole.completedWeight, reason: 'seed=$seed');
        expect(sumEligible, whole.eligibleCount, reason: 'seed=$seed');
        if (whole.value != null) {
          expect(
            whole.value! >= 0 && whole.value! <= 1,
            isTrue,
            reason: 'seed=$seed',
          );
        }
      }
    });
  });
}
