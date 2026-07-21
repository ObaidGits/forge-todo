/// A stable manual ordering rank (R-TASK-003, R-GOAL-005 style fractional
/// ordering; data-model §1 "stable sortable rank plus ID tie-breaker").
///
/// A rank is a non-empty string over the lowercase alphabet `a`–`z`. Ordering
/// is plain lexicographic byte comparison, so ranks can be compared and sorted
/// by SQLite without any custom collation. New ranks are produced *between* two
/// existing ranks (or the open ends) so an insert or reorder never rewrites its
/// neighbours; the ID is the deterministic tie-breaker when two ranks are equal
/// (which only happens across a rebalance, never within one generation).
///
/// The generator guarantees, for any `before < after`, that
/// `before < between(before, after) < after`, and that a generated rank never
/// ends in the lower sentinel character, which keeps the "insert before an
/// immediate successor" case reachable.
extension type const TaskRank(String value) implements String {
  /// The seed rank used for the very first item in an empty ordering. It sits
  /// in the middle of the space so items can be inserted freely on either side.
  static TaskRank get initial => const TaskRank('n');

  /// Validates that [value] is a well-formed rank.
  static TaskRank parse(String value) {
    if (value.isEmpty || !_valid.hasMatch(value)) {
      throw FormatException('Invalid task rank: "$value"');
    }
    return TaskRank(value);
  }

  /// Returns a new rank strictly between [before] and [after].
  ///
  /// A null [before] means "before the first item"; a null [after] means
  /// "after the last item". Throws [ArgumentError] when `before >= after`.
  static TaskRank between(TaskRank? before, TaskRank? after) {
    final String lower = before?.value ?? '';
    final String? upper = after?.value;
    if (upper != null && lower.compareTo(upper) >= 0) {
      throw ArgumentError(
        'Cannot rank between "$lower" and "$upper": out of order.',
      );
    }
    // `_minSentinel` is one below 'a'; `_maxSentinel` is one above 'z'. When a
    // bound is exhausted we fall back to the matching sentinel so the midpoint
    // stays inside the printable alphabet.
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
        return TaskRank(String.fromCharCodes(out));
      }
      // No room at this position: keep the lower char and descend one level.
      out.add(lo);
      i += 1;
    }
  }

  /// The rank that appends a new item after [last] (or the first rank when the
  /// ordering is empty).
  static TaskRank append(TaskRank? last) =>
      last == null ? initial : between(last, null);

  static const int _minSentinel = 96; // one below 'a'
  static const int _maxSentinel = 123; // one above 'z'
  static final RegExp _valid = RegExp(r'^[a-z]+$');
}
