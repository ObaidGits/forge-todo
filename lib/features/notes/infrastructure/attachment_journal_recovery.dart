import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/deletion/deletion_repositories.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/features/notes/application/attachments/managed_file_system.dart';

/// Owner entity type recorded for attachment file-journal entries.
const String _attachmentOwnerType = 'note';

/// The outcome of one durable file-journal recovery sweep.
final class AttachmentRecoveryReport {
  const AttachmentRecoveryReport({
    required this.failedImports,
    required this.completedDeletions,
    required this.reconciledPublished,
  });

  /// Orphaned in-flight imports whose staged/published file was removed and
  /// whose journal was advanced to `failed` (a crash during stage/publish left
  /// no committed metadata).
  final int failedImports;

  /// In-flight deletions whose managed file was removed and whose journal was
  /// advanced to `cleaned` (a crash after journaling but before file removal).
  final int completedDeletions;

  /// Imports found with committed published metadata whose journal was still
  /// in-flight; the journal was advanced to `done` (a crash in the narrow
  /// window between the metadata commit and the journal advance — the file is
  /// live and intact, so nothing is deleted).
  final int reconciledPublished;

  bool get isEmpty =>
      failedImports == 0 && completedDeletions == 0 && reconciledPublished == 0;
}

/// Reconciles the durable managed-attachment file journal against the
/// filesystem at startup after an unexpected process termination (R-NOTE-006,
/// NFR-REL-002, testing.md §5 "journal acknowledgement/recovery/pruning").
///
/// The staged-write pipeline journals every import and deletion durably *before*
/// it mutates the filesystem, and it advances the journal to a terminal state
/// (`done`/`failed`/`cleaned`) in the same transaction that commits or rolls
/// back the metadata. If the process dies between those two durable points, a
/// journal row is left in `pending`/`in_progress` and the filesystem may hold an
/// orphaned staged/published file that no committed metadata references. This
/// sweep restores the invariant that a crash leaves either the old state or the
/// new state, never a partial one:
///
/// * **import** with no committed published metadata → the orphaned file is
///   removed and the journal is advanced to `failed`. A never-published
///   attachment can never leak a file or corrupt a note.
/// * **import** whose published metadata *did* commit → the file is live; the
///   journal is advanced to `done`.
/// * **delete** → the managed file is removed (idempotent) and the journal is
///   advanced to `cleaned`, completing the interrupted deletion.
///
/// The sweep is itself idempotent: terminal journal rows are ignored, so
/// running it again is a no-op.
final class AttachmentJournalRecovery {
  AttachmentJournalRecovery({
    required this.db,
    required this.unitOfWork,
    required this.fileSystem,
    required this.now,
  });

  final ForgeSchemaDatabase db;
  final UnitOfWork unitOfWork;
  final ManagedFileSystem fileSystem;
  final DateTime Function() now;

  int get _nowUtc => now().toUtc().millisecondsSinceEpoch;

  Future<AttachmentRecoveryReport> recover(String profileId) async {
    final List<QueryRow> rows = await db
        .customSelect(
          "SELECT id, operation, staged_path_token, final_path_token "
          'FROM file_journal '
          "WHERE profile_id = ? AND owner_entity_type = ? "
          "AND state IN ('pending', 'in_progress') ORDER BY id",
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(_attachmentOwnerType),
          ],
        )
        .get();

    int failedImports = 0;
    int completedDeletions = 0;
    int reconciledPublished = 0;

    for (final QueryRow row in rows) {
      final Map<String, Object?> data = row.data;
      final String journalId = data['id']! as String;
      final String operation = data['operation']! as String;
      final String? token =
          (data['final_path_token'] as String?) ??
          (data['staged_path_token'] as String?);

      if (operation == 'delete') {
        if (token != null && await fileSystem.managedExists(token)) {
          await fileSystem.deleteManaged(token);
        }
        await _advance(journalId, 'cleaned');
        completedDeletions += 1;
        continue;
      }

      // Import: reconcile against committed published metadata.
      final bool published =
          token != null && await _hasPublishedFor(profileId, token);
      if (published) {
        await _advance(journalId, 'done');
        reconciledPublished += 1;
        continue;
      }
      if (token != null && await fileSystem.managedExists(token)) {
        await fileSystem.deleteManaged(token);
      }
      await _advance(journalId, 'failed');
      failedImports += 1;
    }

    return AttachmentRecoveryReport(
      failedImports: failedImports,
      completedDeletions: completedDeletions,
      reconciledPublished: reconciledPublished,
    );
  }

  Future<bool> _hasPublishedFor(String profileId, String pathToken) async {
    final List<QueryRow> rows = await db
        .customSelect(
          "SELECT 1 AS present FROM attachments "
          "WHERE profile_id = ? AND path_token = ? AND state = 'published' "
          'LIMIT 1',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(pathToken),
          ],
        )
        .get();
    return rows.isNotEmpty;
  }

  Future<void> _advance(String journalId, String state) async {
    await unitOfWork.transaction((TransactionSession tx) async {
      await tx.repositories.resolve<FileJournalRepository>().advance(
        id: journalId,
        state: state,
        nowUtc: _nowUtc,
      );
    });
  }
}
