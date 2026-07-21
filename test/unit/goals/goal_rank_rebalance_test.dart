import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/goals/domain/goal_rank.dart';

/// Sync-safe rank rebalancing via [GoalRank.distribute] (R-GOAL-005).
///
/// A rebalance reassigns fresh, compact ranks to a whole ordered collection.
/// The output must be a deterministic pure function of the item count so two
/// devices converge on byte-identical ranks, and the ranks must be strictly
/// increasing valid ranks that still leave room for future inserts.
///
/// **Validates: Requirements R-GOAL-005**
void main() {
  group('given a non-positive count', () {
    test('then distribute returns an empty list', () {
      expect(GoalRank.distribute(0), isEmpty);
      expect(GoalRank.distribute(-3), isEmpty);
    });
  });

  group('given a positive count', () {
    test('then it returns exactly that many ranks', () {
      expect(GoalRank.distribute(1).length, 1);
      expect(GoalRank.distribute(5).length, 5);
      expect(GoalRank.distribute(50).length, 50);
    });

    test('then every rank is a well-formed a–z rank', () {
      for (final GoalRank rank in GoalRank.distribute(40)) {
        // Parse round-trips only valid ranks.
        expect(GoalRank.parse(rank.value).value, rank.value);
      }
    });

    test('then the ranks are strictly increasing lexicographically', () {
      for (final int n in <int>[1, 2, 3, 7, 26, 27, 100, 700]) {
        final List<GoalRank> ranks = GoalRank.distribute(n);
        for (int i = 1; i < ranks.length; i += 1) {
          expect(
            ranks[i - 1].value.compareTo(ranks[i].value) < 0,
            isTrue,
            reason:
                'n=$n position $i: ${ranks[i - 1].value} !< ${ranks[i].value}',
          );
        }
      }
    });

    test('then it is deterministic across calls (sync-safe convergence)', () {
      expect(GoalRank.distribute(37), GoalRank.distribute(37));
      expect(GoalRank.distribute(1), GoalRank.distribute(1));
    });

    test('then head/tail room remains for future inserts', () {
      final List<GoalRank> ranks = GoalRank.distribute(10);
      // A new item can always be placed before the first and after the last.
      final GoalRank beforeFirst = GoalRank.between(null, ranks.first);
      final GoalRank afterLast = GoalRank.between(ranks.last, null);
      expect(beforeFirst.value.compareTo(ranks.first.value) < 0, isTrue);
      expect(afterLast.value.compareTo(ranks.last.value) > 0, isTrue);
      // And between any adjacent pair.
      for (int i = 1; i < ranks.length; i += 1) {
        final GoalRank mid = GoalRank.between(ranks[i - 1], ranks[i]);
        expect(ranks[i - 1].value.compareTo(mid.value) < 0, isTrue);
        expect(mid.value.compareTo(ranks[i].value) < 0, isTrue);
      }
    });

    test('then rebalancing a bloated ordering shortens the ranks', () {
      // Simulate many inserts between the same neighbours: ranks grow long.
      GoalRank low = GoalRank.initial;
      final GoalRank high = GoalRank.between(low, null);
      GoalRank longest = low;
      for (int i = 0; i < 30; i += 1) {
        low = GoalRank.between(low, high);
        if (low.value.length > longest.value.length) {
          longest = low;
        }
      }
      expect(longest.value.length, greaterThan(3));
      // A rebalance produces compact, evenly-spaced ranks instead.
      final List<GoalRank> rebalanced = GoalRank.distribute(32);
      final int maxLen = rebalanced
          .map((GoalRank r) => r.value.length)
          .reduce((int a, int b) => a > b ? a : b);
      expect(maxLen, lessThanOrEqualTo(2));
    });
  });
}
