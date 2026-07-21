/// A stable manual ordering rank for planning entries (data-model §1 "stable
/// sortable rank plus ID tie-breaker").
///
/// A rank is a non-empty lowercase `a`–`z` string ordered by plain lexicographic
/// byte comparison, so SQLite sorts it without a custom collation. New ranks are
/// produced between two existing ranks (or the open ends) so appending or
/// reordering never rewrites neighbours; the entry id is the deterministic
/// tie-breaker.
///
/// The planner keeps its own small helper rather than importing the tasks
/// feature's rank type, so feature infrastructure boundaries stay independent.
abstract final class PlanningRank {
  /// The seed rank for the first entry in an empty ordering.
  static const String initial = 'n';

  /// Returns a rank strictly between [before] and [after]. A null bound means
  /// the open start/end of the ordering.
  static String between(String? before, String? after) {
    final String lower = before ?? '';
    final String? upper = after;
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
        return String.fromCharCodes(out);
      }
      out.add(lo);
      i += 1;
    }
  }

  /// Appends a new entry after [last] (or the first rank when empty).
  static String append(String? last) =>
      last == null ? initial : between(last, null);

  static const int _minSentinel = 96; // one below 'a'
  static const int _maxSentinel = 123; // one above 'z'
}
