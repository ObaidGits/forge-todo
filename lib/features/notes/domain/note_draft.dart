import 'package:forge/core/domain/id.dart';

/// Recovery status of a durable draft (R-NOTE-005).
enum DraftRecoveryStatus {
  /// The draft is being actively edited; editor memory still holds it.
  active,

  /// Editor memory may be discarded; this draft is the authoritative unsaved
  /// copy and must be offered for recovery on the next open.
  awaitingRecovery;

  String get wire => switch (this) {
    DraftRecoveryStatus.active => 'active',
    DraftRecoveryStatus.awaitingRecovery => 'awaiting_recovery',
  };

  static DraftRecoveryStatus fromWire(String value) => switch (value) {
    'active' => DraftRecoveryStatus.active,
    'awaiting_recovery' => DraftRecoveryStatus.awaitingRecovery,
    _ => throw FormatException('Unknown draft recovery status: $value'),
  };
}

/// A decrypted view of a durable draft journal entry (R-NOTE-005).
///
/// The persisted row stores the [body] encrypted at rest; this value type is
/// the plaintext form returned to the editor after decryption. It pins the
/// [baseRevision] of the note the draft was derived from, which the three-way
/// merge/conflict path (R-NOTE-007, task 9.3) requires as the exact base.
final class NoteDraft {
  const NoteDraft({
    required this.noteId,
    required this.baseRevision,
    required this.body,
    required this.updatedAtUtc,
    required this.recoveryStatus,
  });

  final NoteId noteId;

  /// The exact note revision this draft was based on (R-NOTE-005).
  final int baseRevision;

  /// The plaintext draft Markdown body.
  final String body;

  final int updatedAtUtc;
  final DraftRecoveryStatus recoveryStatus;
}
