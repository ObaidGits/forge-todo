import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/goals/domain/goal_rank.dart';

/// Generative rank properties for stable manual ordering (R-GOAL-005).
///
/// The example-based coverage in `goal_rank_rebalance_test.dart` pins specific
/// counts and neighbours; this suite adds the universal properties across many
/// randomized insert/reorder histories:
///
///  * fractional `between` always yields a valid rank strictly inside its
///    neighbours, so an arbitrary sequence of inserts keeps the collection
///    strictly ordered;
///  * `distribute` (sync-safe rebalance) is a deterministic pure function of
///    the item count — two independent "devices" derive byte-identical ranks —
///    and it preserves the current item order while producing compact,
///    strictly-increasing ranks that still leave head/tail room.
///
/// **Validates: Requirements R-GOAL-005**
void main() {
  group('given randomized fractional inserts (GoalRank.between)', () {
    test('[TEST-GOAL-RANK-BETWEEN-PROP][MVP][TASK-6.6][R-GOAL-005] '
        'every insert stays strictly between its neighbours and the whole '
        'ordering remains strictly increasing and valid', () {
      const int cases = 300;
      for (int seed = 0; seed < cases; seed += 1) {
        final Random rng = Random(0x6A11 ^ seed);
        // Model an ordered list of ranks as it evolves under random inserts.
        final List<GoalRank> order = <GoalRank>[GoalRank.initial];
        final int inserts = 1 + rng.nextInt(40);
        for (int i = 0; i < inserts; i += 1) {
          // Choose an insertion gap: 0 == head, order.length == tail.
          final int gap = rng.nextInt(order.length + 1);
          final GoalRank? before = gap == 0 ? null : order[gap - 1];
          final GoalRank? after = gap == order.length ? null : order[gap];
          final GoalRank inserted = GoalRank.between(before, after);

          // `between` is a pure, deterministic function of its neighbours
          // (sync-safe: two devices computing the same insert converge on a
          // byte-identical rank).
          expect(
            GoalRank.between(before, after).value,
            inserted.value,
            reason: 'seed=$seed insert=$i between not deterministic',
          );
          // Strictly inside the chosen neighbours (the ordering guarantee
          // R-GOAL-005 relies on for stable, sync-deterministic positions —
          // upheld by plain lexicographic byte comparison).
          if (before != null) {
            expect(
              before.value.compareTo(inserted.value) < 0,
              isTrue,
              reason: 'seed=$seed insert=$i not > before',
            );
          }
          if (after != null) {
            expect(
              inserted.value.compareTo(after.value) < 0,
              isTrue,
              reason: 'seed=$seed insert=$i not < after',
            );
          }
          order.insert(gap, inserted);
        }

        // The full collection is strictly increasing with no collisions.
        for (int i = 1; i < order.length; i += 1) {
          expect(
            order[i - 1].value.compareTo(order[i].value) < 0,
            isTrue,
            reason:
                'seed=$seed position $i not strictly increasing: '
                '${order[i - 1].value} !< ${order[i].value}',
          );
        }
      }
    });

    test('a plain interior insert yields a valid a–z rank', () {
      // The common reorder case (insert between two ordinary letters) produces
      // a well-formed a–z rank that round-trips through parse.
      final GoalRank mid = GoalRank.between(
        const GoalRank('a'),
        const GoalRank('c'),
      );
      expect(GoalRank.parse(mid.value).value, mid.value);
      expect('a'.compareTo(mid.value) < 0, isTrue);
      expect(mid.value.compareTo('c') < 0, isTrue);
    });

    test('between rejects an out-of-order neighbour pair', () {
      expect(
        () => GoalRank.between(const GoalRank('t'), const GoalRank('t')),
        throwsArgumentError,
      );
      expect(
        () => GoalRank.between(const GoalRank('z'), const GoalRank('b')),
        throwsArgumentError,
      );
    });
  });

  group('given a sync-safe rebalance (GoalRank.distribute)', () {
    test('[TEST-GOAL-RANK-DISTRIBUTE-PROP][MVP][TASK-6.6][R-GOAL-005] '
        'distribute is deterministic across devices and yields strictly '
        'increasing, valid, order-preserving ranks with head/tail room', () {
      const int cases = 250;
      for (int seed = 0; seed < cases; seed += 1) {
        final Random rng = Random(0x6AD1 ^ seed);
        final int n = 1 + rng.nextInt(300);

        final List<GoalRank> a = GoalRank.distribute(n);
        final List<GoalRank> b = GoalRank.distribute(n);

        // Determinism: a second, independent computation is byte-identical,
        // so two devices converge on the same ranks without a merge.
        expect(a, b, reason: 'seed=$seed distribute not deterministic');
        expect(a.length, n, reason: 'seed=$seed wrong length');

        for (int i = 0; i < n; i += 1) {
          expect(
            GoalRank.parse(a[i].value).value,
            a[i].value,
            reason: 'seed=$seed rank $i invalid',
          );
        }
        for (int i = 1; i < n; i += 1) {
          expect(
            a[i - 1].value.compareTo(a[i].value) < 0,
            isTrue,
            reason: 'seed=$seed not strictly increasing at $i',
          );
        }

        // Head/tail room always remains for a future insert.
        expect(
          GoalRank.between(null, a.first).value.compareTo(a.first.value) < 0,
          isTrue,
          reason: 'seed=$seed no head room',
        );
        expect(
          GoalRank.between(a.last, null).value.compareTo(a.last.value) > 0,
          isTrue,
          reason: 'seed=$seed no tail room',
        );
      }
    });

    test(
      'rebalancing a bloated ordering preserves item order and compacts ranks',
      () {
        const int cases = 120;
        for (int seed = 0; seed < cases; seed += 1) {
          final Random rng = Random(0x6ABA ^ seed);

          // Build a bloated ordering by repeatedly inserting between the same
          // narrowing neighbours, tagging each item with a stable identity in
          // its current visual order.
          final List<_Item> items = <_Item>[_Item(0, GoalRank.initial)];
          final int inserts = 5 + rng.nextInt(30);
          for (int i = 1; i <= inserts; i += 1) {
            final int gap = rng.nextInt(items.length + 1);
            final GoalRank? before = gap == 0 ? null : items[gap - 1].rank;
            final GoalRank? after = gap == items.length
                ? null
                : items[gap].rank;
            items.insert(gap, _Item(i, GoalRank.between(before, after)));
          }

          final List<int> orderBefore = items.map((_Item it) => it.id).toList();

          // A rebalance reassigns distribute(n) ranks to the items in their
          // current order (R-GOAL-005).
          final List<GoalRank> fresh = GoalRank.distribute(items.length);
          for (int i = 0; i < items.length; i += 1) {
            items[i] = _Item(items[i].id, fresh[i]);
          }

          // Re-sorting by the new ranks preserves the exact prior order.
          items.sort(
            (_Item x, _Item y) => x.rank.value.compareTo(y.rank.value),
          );
          expect(
            items.map((_Item it) => it.id).toList(),
            orderBefore,
            reason: 'seed=$seed rebalance changed the item order',
          );

          // The rebalanced ranks are compact: no rank is longer than the
          // fixed base-26 width needed for this count.
          final int maxLen = items
              .map((_Item it) => it.rank.value.length)
              .reduce((int x, int y) => x > y ? x : y);
          final int expectedWidth = _base26Width(items.length + 1);
          expect(
            maxLen,
            lessThanOrEqualTo(expectedWidth),
            reason: 'seed=$seed ranks not compact after rebalance',
          );
        }
      },
    );
  });
}

/// The fixed base-26 width `distribute` uses to hold `divisions - 1` interior
/// points (mirrors the domain generator so the test asserts real compaction).
int _base26Width(int divisions) {
  int width = 1;
  int space = 26;
  while (space < divisions) {
    width += 1;
    space *= 26;
  }
  return width;
}

final class _Item {
  const _Item(this.id, this.rank);
  final int id;
  final GoalRank rank;
}
