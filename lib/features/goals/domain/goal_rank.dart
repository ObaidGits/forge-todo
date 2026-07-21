/// A stable manual ordering rank for goals and milestones (R-GOAL-005;
/// data-model §1 "stable sortable rank plus ID tie-breaker").
///
/// A rank is a non-empty string over the lowercase alphabet `a`–`z`. Ordering
/// is plain lexicographic byte comparison, so ranks can be compared and sorted
/// by SQLite without any custom collation. New ranks are produced *between* two
/// existing ranks (or the open ends) so an insert or reorder never rewrites its
/// neighbours; the ID is the deterministic tie-breaker when two ranks are equal
/// (which only happens across a rebalance, never within one generation).
///
/// The generator guarantees, for any `before < after`, that
/// `before < between(before, after) < after`.
extension type const GoalRank(String value) implements String {
  /// The seed rank used for the very first item in an empty ordering. It sits
  /// in the middle of the space so items can be inserted freely on either side.
  static GoalRank get initial => const GoalRank('n');

  /// Validates that [value] is a well-formed rank.
  static GoalRank parse(String value) {
    if (value.isEmpty || !_valid.hasMatch(value)) {
      throw FormatException('Invalid goal rank: "$value"');
    }
    return GoalRank(value);
  }

  /// Returns a new rank strictly between [before] and [after].
  ///
  /// A null [before] means "before the first item"; a null [after] means
  /// "after the last item". Throws [ArgumentError] when `before >= after`.
  static GoalRank between(GoalRank? before, GoalRank? after) {
    final String lower = before?.value ?? '';
    final String? upper = after?.value;
    if (upper != null && lower.compareTo(upper) >= 0) {
      throw ArgumentError(
        'Cannot rank between "$lower" and "$upper": out of order.',
      );
    }
    final List<int> out = <int>[];
    int i = 0;
    while (true) {
      final int lo = i < lower.length ? lower.codeUnitAt(i) : _minSentinel;
      final int hi = (upper != null && i < upper.length)
          ? upper.codeUnitAt(i)
          : _maxSentinel;
      final int mid = (lo + hi) ~/ 2;
      if (mid != lo) {
        out.add(mid);
        return GoalRank(String.fromCharCodes(out));
      }
      // No room at this position: keep the lower char and descend one level.
      out.add(lo);
      i += 1;
    }
  }

  /// The rank that appends a new item after [last] (or the first rank when the
  /// ordering is empty).
  static GoalRank append(GoalRank? last) =>
      last == null ? initial : between(last, null);

  /// Produces [count] evenly-spaced, strictly-increasing ranks for a
  /// **sync-safe rebalance** (R-GOAL-005; data-model §1/§6 "Rebalance is
  /// transactional and sync-aware", conflict rule 6 "rebalance is an explicit
  /// semantic group").
  ///
  /// Repeated fractional inserts between the same two neighbours make ranks
  /// grow without bound; a rebalance reassigns fresh, compact ranks to a whole
  /// ordered collection in one command. The output is a pure function of
  /// [count]: every device computing `distribute(n)` derives byte-identical
  /// ranks, so a rebalance replays deterministically and converges without a
  /// special merge — the collection is reordered by applying these ranks to the
  /// items in their current order.
  ///
  /// The ranks are fixed-width base-26 (`a`–`z`) values placed at
  /// `space * i / (count + 1)` for `i` in `1..count`, so they are strictly
  /// increasing, never collide, and always leave head/tail room for future
  /// inserts. Returns an empty list for a non-positive [count].
  static List<GoalRank> distribute(int count) {
    if (count <= 0) {
      return const <GoalRank>[];
    }
    final BigInt divisions = BigInt.from(count + 1);
    // Smallest width whose base-26 space can hold `count` interior points.
    int width = 1;
    BigInt space = BigInt.from(26);
    while (space < divisions) {
      width += 1;
      space *= BigInt.from(26);
    }
    final List<GoalRank> ranks = List<GoalRank>.filled(count, initial);
    for (int i = 1; i <= count; i += 1) {
      final BigInt value = (space * BigInt.from(i)) ~/ divisions;
      ranks[i - 1] = GoalRank(_encodeBase26(value, width));
    }
    return ranks;
  }

  /// Encodes [value] as exactly [width] lowercase base-26 digits (`a`–`z`),
  /// most-significant digit first, so fixed-width ranks sort lexicographically
  /// in numeric order.
  static String _encodeBase26(BigInt value, int width) {
    final List<int> chars = List<int>.filled(width, _a);
    BigInt v = value;
    final BigInt base = BigInt.from(26);
    for (int pos = width - 1; pos >= 0; pos -= 1) {
      final BigInt digit = v % base;
      chars[pos] = _a + digit.toInt();
      v = v ~/ base;
    }
    return String.fromCharCodes(chars);
  }

  static const int _a = 97; // 'a'
  static const int _minSentinel = 96; // one below 'a'
  static const int _maxSentinel = 123; // one above 'z'
  static final RegExp _valid = RegExp(r'^[a-z]+$');
}
