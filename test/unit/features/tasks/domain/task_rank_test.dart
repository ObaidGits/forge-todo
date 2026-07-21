import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/tasks/domain/task_rank.dart';

/// Stable manual ordering rank tests (R-TASK-003).
///
/// **Validates: Requirements R-TASK-003**
void main() {
  group('given TaskRank.between when inserting between two ranks', () {
    test('then the result is strictly ordered between the bounds', () {
      final TaskRank a = TaskRank.initial;
      final TaskRank b = TaskRank.append(a);
      final TaskRank mid = TaskRank.between(a, b);
      expect(a.value.compareTo(mid.value) < 0, isTrue);
      expect(mid.value.compareTo(b.value) < 0, isTrue);
    });

    test('then between(null, first) produces a smaller rank', () {
      final TaskRank first = TaskRank.initial;
      final TaskRank before = TaskRank.between(null, first);
      expect(before.value.compareTo(first.value) < 0, isTrue);
    });

    test('then append yields an increasing sequence', () {
      TaskRank? last;
      final List<String> ranks = <String>[];
      for (int i = 0; i < 100; i += 1) {
        final TaskRank next = TaskRank.append(last);
        ranks.add(next.value);
        last = next;
      }
      final List<String> sorted = List<String>.of(ranks)..sort();
      expect(ranks, orderedEquals(sorted));
    });

    test('then out-of-order bounds are rejected', () {
      expect(
        () => TaskRank.between(const TaskRank('z'), const TaskRank('b')),
        throwsArgumentError,
      );
      expect(
        () => TaskRank.between(const TaskRank('m'), const TaskRank('m')),
        throwsArgumentError,
      );
    });

    test('then parse rejects malformed ranks', () {
      expect(() => TaskRank.parse(''), throwsFormatException);
      expect(() => TaskRank.parse('A1'), throwsFormatException);
      expect(TaskRank.parse('abc').value, 'abc');
    });
  });

  group('given many random reorders (generative)', () {
    test('then global order and uniqueness always hold', () {
      // Deterministic seed keeps this reproducible; a failing seed would be
      // pinned as a regression fixture (testing.md §4).
      final Random random = Random(20240601);
      for (int trial = 0; trial < 200; trial += 1) {
        final List<String> order = <String>[TaskRank.initial.value];
        for (int op = 0; op < 40; op += 1) {
          final int index = random.nextInt(order.length + 1);
          final String? before = index == 0 ? null : order[index - 1];
          final String? after = index == order.length ? null : order[index];
          final String inserted = TaskRank.between(
            before == null ? null : TaskRank(before),
            after == null ? null : TaskRank(after),
          ).value;
          // Strictly between its neighbours.
          if (before != null) {
            expect(
              before.compareTo(inserted) < 0,
              isTrue,
              reason: 'trial $trial: "$before" !< "$inserted"',
            );
          }
          if (after != null) {
            expect(
              inserted.compareTo(after) < 0,
              isTrue,
              reason: 'trial $trial: "$inserted" !< "$after"',
            );
          }
          order.insert(index, inserted);
        }
        // The whole list is strictly increasing and unique.
        final List<String> sorted = List<String>.of(order)..sort();
        expect(order, orderedEquals(sorted), reason: 'trial $trial not sorted');
        expect(order.toSet().length, order.length, reason: 'trial $trial dup');
      }
    });
  });
}
