/// The kind of an immutable study-session lifecycle event (R-LEARN-002,
/// R-FOCUS-005).
///
/// The study-session log is append-only: a `logged` event records a session as
/// it was first captured; a `corrected` event supersedes a prior version with
/// revised facts; an `undone` event supersedes a correction to restore the
/// prior visible state. No event ever rewrites an earlier one — history is
/// preserved by appending a superseding event.
enum StudySessionEventKind {
  logged('logged'),
  corrected('corrected'),
  undone('undone');

  const StudySessionEventKind(this.wire);

  final String wire;

  static StudySessionEventKind fromWire(String wire) {
    for (final StudySessionEventKind kind in StudySessionEventKind.values) {
      if (kind.wire == wire) {
        return kind;
      }
    }
    throw FormatException('Unknown StudySessionEventKind "$wire".');
  }
}
