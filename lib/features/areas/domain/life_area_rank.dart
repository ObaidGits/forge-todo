/// A stable manual ordering rank for Life Areas (R-GEN-002; data-model §1
/// "stable sortable rank plus ID tie-breaker").
///
/// A rank is a non-empty string over the lowercase alphabet `a`–`z`. Ordering
/// is plain lexicographic byte comparison, so ranks can be compared and sorted
/// by SQLite without any custom collation. New ranks are produced *between* two
/// existing ranks (or the open ends) so an insert or reorder never rewrites its
/// neighbours; the id is the deterministic tie-breaker when two ranks are equal.
///
/// The areas feature owns its own rank type so it never imports another
/// feature's domain (design.md §16); the algorithm mirrors the proven
/// fractional-rank generator used elsewhere in the app.
extension type const LifeAreaRank(String value) implements String {
  /// The seed rank used for the very first area in an empty ordering. It sits
  /// in the middle of the space so areas can be inserted freely on either side.
  static LifeAreaRank get initial => const LifeAreaRank('n');

  /// Validates that [value] is a well-formed rank.
  static LifeAreaRank parse(String value) {
    if (value.isEmpty || !_valid.hasMatch(value)) {
      throw FormatException('Invalid life area rank: "$value"');
    }
    return LifeAreaRank(value);
  }

  /// Returns a new rank strictly between [before] and [after].
  ///
  /// A null [before] means "before the first area"; a null [after] means
  /// "after the last area". Throws [ArgumentError] when `before >= after`.
  static LifeAreaRank between(LifeAreaRank? before, LifeAreaRank? after) {
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
        return LifeAreaRank(String.fromCharCodes(out));
      }
      out.add(lo);
      i += 1;
    }
  }

  /// The rank that appends a new area after [last] (or the first rank when the
  /// ordering is empty).
  static LifeAreaRank append(LifeAreaRank? last) =>
      last == null ? initial : between(last, null);

  static const int _minSentinel = 96; // one below 'a'
  static const int _maxSentinel = 123; // one above 'z'
  static final RegExp _valid = RegExp(r'^[a-z]+$');
}
