import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notes/application/note_commands.dart';

/// The durable note command surface (R-GEN-005, R-NOTE-001, R-NOTE-002).
///
/// Every method commits one atomic transaction through the command bus and
/// returns the stable committed result. The canonical Markdown body, the
/// unified search document and the outgoing `[[wiki-link]]` set are maintained
/// in that same commit (R-NOTE-004). [commandId] makes each call idempotent.
///
/// Trash/restore reuse the shared deletion kernel (R-GEN-003) rather than a
/// note-specific delete command.
abstract interface class NoteCommandService {
  /// Creates a note. The result payload carries the generated note id.
  Future<Result<CommittedCommandResult>> create({
    required CommandId commandId,
    required ProfileId profileId,
    required CreateNoteInput input,
  });

  /// Patches an existing note (title/body/area).
  Future<Result<CommittedCommandResult>> update({
    required CommandId commandId,
    required ProfileId profileId,
    required NoteId noteId,
    required UpdateNoteInput input,
  });

  /// Pins or unpins a note (R-NOTE-002).
  Future<Result<CommittedCommandResult>> setPinned({
    required CommandId commandId,
    required ProfileId profileId,
    required NoteId noteId,
    required bool pinned,
  });

  /// Archives or unarchives a note (R-NOTE-002).
  Future<Result<CommittedCommandResult>> setArchived({
    required CommandId commandId,
    required ProfileId profileId,
    required NoteId noteId,
    required bool archived,
  });

  /// Explicitly binds an ambiguous `[[wiki-link]]` to the user-chosen note
  /// (R-NOTE-003). The chosen note must be one of the live candidates sharing
  /// the link's target title; Forge never silently picks for the user.
  Future<Result<CommittedCommandResult>> resolveLink({
    required CommandId commandId,
    required ProfileId profileId,
    required String linkId,
    required NoteId chosenNoteId,
  });

  /// Links a note to another domain entity (task/goal/roadmap/Learning
  /// Resource/habit) through `entity_links` (R-NOTE-002). Cross-profile targets
  /// are rejected (R-GEN-002).
  Future<Result<CommittedCommandResult>> linkEntity({
    required CommandId commandId,
    required ProfileId profileId,
    required NoteId noteId,
    required String targetType,
    required String targetId,
  });

  /// Removes a note→entity link (R-NOTE-002). Idempotent.
  Future<Result<CommittedCommandResult>> unlinkEntity({
    required CommandId commandId,
    required ProfileId profileId,
    required NoteId noteId,
    required String targetType,
    required String targetId,
  });
}
