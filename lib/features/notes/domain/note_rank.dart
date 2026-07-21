/// A stable manual ordering rank for notes (data-model §1 "stable sortable rank
/// plus ID tie-breaker").
///
/// A rank is a non-empty string over the lowercase alphabet `a`–`z`. Ordering
/// is plain lexicographic byte comparison, so ranks sort in SQLite without a
/// custom collation. New ranks are produced *between* two existing ranks (or
/// the open ends) so an insert or reorder never rewrites its neighbours. This
/// mirrors the task rank algorithm; notes keep their own type so the ordering
/// space stays feature-owned.
extension type const NoteRank(String value) implements String {
  /// The seed rank for the first item in an empty ordering.
  static NoteRank get initial => const NoteRank('n');

  static NoteRank parse(String value) {
    if (value.isEmpty || !_valid.hasMatch(value)) {
      throw FormatException('Invalid note rank: "$value"');
    }
    return NoteRank(value);
  }

  /// Returns a new rank strictly between [before] and [after].
  static NoteRank between(NoteRank? before, NoteRank? after) {
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
        return NoteRank(String.fromCharCodes(out));
      }
      out.add(lo);
      i += 1;
    }
  }

  /// The rank that appends a new note after [last] (or the first rank when the
  /// ordering is empty).
  static NoteRank append(NoteRank? last) =>
      last == null ? initial : between(last, null);

  static const int _minSentinel = 96; // one below 'a'
  static const int _maxSentinel = 123; // one above 'z'
  static final RegExp _valid = RegExp(r'^[a-z]+$');
}
