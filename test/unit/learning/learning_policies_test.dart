import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/time_span.dart';
import 'package:forge/features/learning/domain/learning_item.dart';
import 'package:forge/features/learning/domain/learning_item_type.dart';
import 'package:forge/features/learning/domain/learning_policies.dart';
import 'package:forge/features/learning/domain/learning_progress_mode.dart';

LearningItem _item(
  String id, {
  LearningItemType type = LearningItemType.lesson,
  bool complete = false,
  String rank = 'n',
}) {
  return LearningItem(
    id: id,
    profileId: 'p',
    courseId: 'c',
    title: 'Item $id',
    type: type,
    rank: rank,
    completedAtUtc: complete ? 10 : null,
    createdAtUtc: 0,
    updatedAtUtc: 0,
  );
}

void main() {
  group('LearningPolicies.deriveProgress (R-LEARN-004)', () {
    test('given no eligible items when derived then not started', () {
      final LearningProgress progress = LearningPolicies.deriveProgress(
        <LearningItem>[_item('s', type: LearningItemType.section)],
      );
      expect(progress.isStarted, isFalse);
      expect(progress.eligibleCount, 0);
      expect(identical(progress, LearningProgress.notStarted), isTrue);
    });

    test('given empty resource when derived then not started', () {
      final LearningProgress progress = LearningPolicies.deriveProgress(
        const <LearningItem>[],
      );
      expect(progress.isStarted, isFalse);
    });

    test(
      'given some completed eligible items then fraction is completed/eligible',
      () {
        final LearningProgress progress = LearningPolicies.deriveProgress(
          <LearningItem>[
            _item('a', complete: true),
            _item('b', complete: true),
            _item('c'),
            _item('d'),
            // sections never count toward eligibility.
            _item('s', type: LearningItemType.section),
          ],
        );
        expect(progress.isStarted, isTrue);
        expect(progress.eligibleCount, 4);
        expect(progress.completedCount, 2);
        expect(progress.fraction, 0.5);
      },
    );

    test('given manual mode then uses clamped manual value and is started', () {
      final LearningProgress progress = LearningPolicies.deriveProgress(
        <LearningItem>[_item('a')],
        mode: LearningProgressMode.manual,
        manualPermille: 250,
      );
      expect(progress.isStarted, isTrue);
      expect(progress.mode, LearningProgressMode.manual);
      expect(progress.fraction, 0.25);
    });

    test(
      'given manual mode with zero then shows 0 percent not not-started',
      () {
        final LearningProgress progress = LearningPolicies.deriveProgress(
          const <LearningItem>[],
          mode: LearningProgressMode.manual,
          manualPermille: 0,
        );
        expect(progress.isStarted, isTrue);
        expect(progress.fraction, 0);
      },
    );

    test('given manual value beyond range then clamps to 0..1', () {
      expect(
        LearningPolicies.deriveProgress(
          const <LearningItem>[],
          mode: LearningProgressMode.manual,
          manualPermille: 5000,
        ).fraction,
        1.0,
      );
      expect(
        LearningPolicies.deriveProgress(
          const <LearningItem>[],
          mode: LearningProgressMode.manual,
          manualPermille: -100,
        ).fraction,
        0.0,
      );
    });
  });

  group('LearningPolicies.resolveResume (R-LEARN-003)', () {
    test('given all complete then resume is none', () {
      final ResumePoint point = LearningPolicies.resolveResume(<LearningItem>[
        _item('a', complete: true, rank: 'a'),
        _item('b', complete: true, rank: 'b'),
      ]);
      expect(point.itemId, isNull);
      expect(point.reason, 'complete');
    });

    test('given no study history then resume is first incomplete by rank', () {
      final ResumePoint point = LearningPolicies.resolveResume(<LearningItem>[
        _item('a', complete: true, rank: 'a'),
        _item('b', rank: 'b'),
        _item('c', rank: 'c'),
      ]);
      expect(point.itemId, 'b');
      expect(point.reason, 'first_incomplete');
    });

    test('given last studied item still incomplete then resume returns it', () {
      final ResumePoint point = LearningPolicies.resolveResume(<LearningItem>[
        _item('a', complete: true, rank: 'a'),
        _item('b', rank: 'b'),
        _item('c', rank: 'c'),
      ], lastStudiedItemId: 'c');
      expect(point.itemId, 'c');
      expect(point.reason, 'last_studied');
    });

    test(
      'given last studied item now complete then falls back to first incomplete',
      () {
        final ResumePoint point = LearningPolicies.resolveResume(<LearningItem>[
          _item('a', rank: 'a'),
          _item('b', complete: true, rank: 'b'),
        ], lastStudiedItemId: 'b');
        expect(point.itemId, 'a');
        expect(point.reason, 'first_incomplete');
      },
    );

    test('sections are never a resume target', () {
      final ResumePoint point = LearningPolicies.resolveResume(<LearningItem>[
        _item('s', type: LearningItemType.section, rank: 'a'),
        _item('b', complete: true, rank: 'b'),
      ]);
      expect(point.itemId, isNull);
    });
  });

  group('LearningPolicies.unionDuration (R-FOCUS-005)', () {
    TimeSpan span(int startUtc, int endUtc) =>
        TimeSpan(startUtc: startUtc, endUtc: endUtc);

    test('given disjoint intervals then sums lengths', () {
      final int total = LearningPolicies.unionDuration(<TimeSpan>[
        span(0, 100),
        span(200, 250),
      ]);
      expect(total, 150);
    });

    test('given overlapping intervals then counts overlap once', () {
      final int total = LearningPolicies.unionDuration(<TimeSpan>[
        span(0, 100),
        span(50, 150),
      ]);
      expect(total, 150);
    });

    test('given fully contained interval then outer length only', () {
      final int total = LearningPolicies.unionDuration(<TimeSpan>[
        span(0, 100),
        span(25, 75),
      ]);
      expect(total, 100);
    });

    test('given adjacent touching intervals then merges', () {
      final int total = LearningPolicies.unionDuration(<TimeSpan>[
        span(0, 100),
        span(100, 200),
      ]);
      expect(total, 200);
    });

    test('given zero-length intervals then contributes nothing', () {
      final int total = LearningPolicies.unionDuration(<TimeSpan>[
        span(50, 50),
        span(0, 10),
      ]);
      expect(total, 10);
    });

    test('given empty list then zero', () {
      expect(LearningPolicies.unionDuration(const <TimeSpan>[]), 0);
    });

    test('given unsorted intervals then order independent', () {
      final int total = LearningPolicies.unionDuration(<TimeSpan>[
        span(300, 400),
        span(0, 100),
        span(90, 120),
      ]);
      // [0,120] ∪ [300,400] = 120 + 100
      expect(total, 220);
    });
  });
}
