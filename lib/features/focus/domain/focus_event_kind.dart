/// The kind of an immutable focus-session lifecycle event (R-FOCUS-003).
///
/// The focus event log is append-only. A [started] event opens a session;
/// [paused]/[resumed] bracket a pause; [ended] closes the session. A
/// [corrected] event supersedes a prior event with revised facts and a
/// [cancelled] event abandons an open session. No event ever rewrites an
/// earlier one — history is preserved by appending a superseding event, and
/// corrections are audit records rather than history rewrites (R-FOCUS-003,
/// R-FOCUS-005).
enum FocusEventKind {
  started('started'),
  paused('paused'),
  resumed('resumed'),
  ended('ended'),
  cancelled('cancelled'),
  corrected('corrected'),
  undone('undone');

  const FocusEventKind(this.wire);

  final String wire;

  static FocusEventKind fromWire(String wire) {
    for (final FocusEventKind kind in FocusEventKind.values) {
      if (kind.wire == wire) {
        return kind;
      }
    }
    throw FormatException('Unknown focus event kind: $wire');
  }
}
