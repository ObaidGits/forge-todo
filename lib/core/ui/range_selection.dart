/// Pure, framework-free multi-selection logic for ordered lists.
///
/// Desktop list multi-selection follows the platform-conventional model
/// (ux-design §9): a plain click selects one item, Ctrl/Cmd-click toggles an
/// item without clearing the rest, and Shift-click extends a contiguous range
/// from the last anchor. This model is deliberately UI-toolkit agnostic so it
/// can be unit-tested exhaustively and reused by any list. It stores selection
/// as a set of stable item ids plus an anchor id used for range extension.
///
/// It carries no domain rules and no Flutter/Drift imports (NFR-MAIN-001).
final class RangeSelection {
  const RangeSelection({this.ids = const <String>{}, this.anchor});

  /// The currently selected item ids.
  final Set<String> ids;

  /// The anchor used by Shift-range extension, or null when there is none.
  final String? anchor;

  bool get isEmpty => ids.isEmpty;
  int get count => ids.length;
  bool contains(String id) => ids.contains(id);

  /// A plain click: select only [id] and make it the anchor.
  RangeSelection selectOnly(String id) =>
      RangeSelection(ids: <String>{id}, anchor: id);

  /// Ctrl/Cmd-click: toggle [id] in place, keeping other selections. The
  /// toggled item becomes the new anchor when added; when removed the anchor
  /// falls back to null so the next Shift-click starts a fresh range.
  RangeSelection toggle(String id) {
    final Set<String> next = Set<String>.of(ids);
    final bool added = next.add(id);
    if (!added) {
      next.remove(id);
    }
    return RangeSelection(ids: next, anchor: added ? id : null);
  }

  /// Shift-click: extend a contiguous range over [order] from the current
  /// anchor to [id] (inclusive). The range replaces any prior range but the
  /// anchor is preserved so successive Shift-clicks re-extend from it, matching
  /// desktop file managers. When there is no anchor this behaves like
  /// [selectOnly].
  RangeSelection extendTo(String id, List<String> order) {
    final String? from = anchor;
    if (from == null || !order.contains(from) || !order.contains(id)) {
      return selectOnly(id);
    }
    final int start = order.indexOf(from);
    final int end = order.indexOf(id);
    final int lo = start <= end ? start : end;
    final int hi = start <= end ? end : start;
    final Set<String> next = <String>{for (int i = lo; i <= hi; i++) order[i]};
    return RangeSelection(ids: next, anchor: from);
  }

  /// Selects every id in [order] and anchors on the first.
  RangeSelection selectAll(List<String> order) => RangeSelection(
    ids: order.toSet(),
    anchor: order.isEmpty ? null : order.first,
  );

  /// Clears the selection and the anchor.
  RangeSelection clear() => const RangeSelection();

  /// Drops any selected ids that are no longer present in [order] (for example
  /// after a list reload) and clears a stale anchor. Keeps selection honest so
  /// batch actions never target vanished rows.
  RangeSelection pruneTo(List<String> order) {
    final Set<String> present = order.toSet();
    final Set<String> next = ids.where(present.contains).toSet();
    final String? nextAnchor = (anchor != null && present.contains(anchor))
        ? anchor
        : null;
    return RangeSelection(ids: next, anchor: nextAnchor);
  }
}

/// The pointer modifiers that influence a list click. Kept toolkit-neutral so
/// the pure model has no Flutter dependency; presentation maps hardware key
/// state onto this.
enum SelectionModifier {
  /// No modifier: replace selection with the clicked item.
  none,

  /// Ctrl (Windows/Linux) or Cmd (macOS): toggle the clicked item.
  toggle,

  /// Shift: extend a contiguous range from the anchor.
  range,
}

/// Applies a click on [id] within [order] under [modifier], returning the next
/// selection. This is the single decision point the UI calls for every click.
RangeSelection applySelectionClick({
  required RangeSelection current,
  required String id,
  required List<String> order,
  required SelectionModifier modifier,
}) {
  return switch (modifier) {
    SelectionModifier.none => current.selectOnly(id),
    SelectionModifier.toggle => current.toggle(id),
    SelectionModifier.range => current.extendTo(id, order),
  };
}
