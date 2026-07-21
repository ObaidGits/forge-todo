import 'dart:typed_data';

import 'package:forge/app/infrastructure/database/deletion/deletion_repositories.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/security/key_vault.dart';
import 'package:forge/features/notes/application/attachments/attachment_crypto.dart';
import 'package:forge/features/notes/application/attachments/attachment_store.dart';
import 'package:forge/features/notes/application/attachments/managed_file_system.dart';
import 'package:forge/features/notes/domain/attachments/attachment.dart';
import 'package:forge/features/notes/domain/attachments/attachment_content_type.dart';
import 'package:forge/features/notes/domain/attachments/attachment_quota.dart';
import 'package:forge/features/notes/domain/attachments/attachment_rejection.dart';
import 'package:forge/features/notes/infrastructure/attachment_repository.dart';

/// Owner entity type recorded in the durable file journal for attachments.
const String _attachmentOwnerType = 'note';
const String _importOperation = 'import';
const String _deleteOperation = 'delete';

/// Security-first staged-write managed attachment store (R-NOTE-006, R-SEC-002,
/// R-SEC-005).
///
/// The import pipeline never trusts the source and never exposes a half-written
/// file:
///
/// 1. Open the source under TOCTOU-safe discipline and validate the *opened
///    descriptor* is a regular file; reject symlinks/special files and any
///    content that changed between open and read.
/// 2. Detect the type from magic bytes and reject a type outside the accepted
///    set or one that disagrees with the declared MIME.
/// 3. Enforce per-file/count/profile quota against live totals.
/// 4. Encrypt content with a fresh per-file DEK and wrap the DEK under the
///    device KEK released by the [KeyVault]; the DEK plaintext is wiped.
/// 5. Journal the import durably, stage the ciphertext, fsync it, then publish
///    with an atomic rename + directory fsync.
/// 6. Insert metadata and advance the journal to `done` in one transaction,
///    re-checking quota to close any race. Any failure cleans up and marks the
///    journal `failed`, never corrupting a note.
///
/// Deletion journals durably before removing the file. Opens decrypt to a
/// controlled location and verify the pinned content hash; external open
/// requires explicit confirmation and a least-lived temp grant.
final class StagedAttachmentStore implements AttachmentStore {
  StagedAttachmentStore({
    required this.unitOfWork,
    required this.reads,
    required this.fileSystem,
    required this.crypto,
    required this.keyVault,
    required this.now,
    this.typePolicy = const AttachmentTypePolicy(),
    this.quota = AttachmentQuota.defaults,
  });

  final UnitOfWork unitOfWork;
  final AttachmentReadRepository reads;
  final ManagedFileSystem fileSystem;
  final AttachmentCrypto crypto;
  final KeyVault keyVault;
  final AttachmentTypePolicy typePolicy;
  final AttachmentQuota quota;
  final DateTime Function() now;

  int get _nowUtc => now().toUtc().millisecondsSinceEpoch;

  /// The opaque internal path token for an attachment. Attachment IDs are
  /// validated to a safe charset, so the token can never carry traversal.
  String _pathToken(String attachmentId) => '$attachmentId.att';

  @override
  Future<Attachment> importAttachment(AttachmentImportRequest request) async {
    // Step 1 — TOCTOU-safe open + regular-file validation + read.
    final Uint8List plaintext = await _readTrustedSource(request.sourcePath);

    // Step 2 — content-type validation from magic bytes.
    final DetectedContentType detected = typePolicy.validate(
      header: plaintext.length <= AttachmentTypePolicy.sniffLength
          ? plaintext
          : Uint8List.sublistView(
              plaintext,
              0,
              AttachmentTypePolicy.sniffLength,
            ),
      declaredMime: request.declaredMime,
    );

    // Step 3 — quota pre-check against live totals.
    final AttachmentTotals totals = await reads.publishedTotals(
      request.profileId,
    );
    quota.enforce(
      fileBytes: plaintext.length,
      profileBytes: totals.bytes,
      profileCount: totals.count,
    );

    final String contentHash = crypto.contentHashHex(plaintext);

    // Step 4 — per-file DEK, wrapped under the device KEK.
    final Uint8List dek = crypto.newDek();
    final Uint8List ciphertext;
    final String wrappedDek;
    try {
      ciphertext = crypto.sealContent(plaintext: plaintext, dek: dek);
      wrappedDek = await _wrapDek(dek);
    } finally {
      crypto.wipe(dek);
    }

    final String token = _pathToken(request.attachmentId);
    final String journalId = 'attach-import-${request.attachmentId}';

    // Step 5a — journal the import durably before touching the filesystem.
    await unitOfWork.transaction((TransactionSession tx) async {
      await tx.repositories.resolve<FileJournalRepository>().record(
        id: journalId,
        profileId: request.profileId,
        operation: _importOperation,
        state: 'in_progress',
        nowUtc: _nowUtc,
        ownerEntityType: _attachmentOwnerType,
        ownerEntityId: request.noteId,
        stagedPathToken: token,
        finalPathToken: token,
        expectedHash: contentHash,
        expectedBytes: plaintext.length,
      );
    });

    // Step 5b — stage, fsync, then atomically publish the ciphertext.
    final StagedFile staged = await fileSystem.beginStaging(token);
    try {
      await staged.write(ciphertext);
      await staged.sync();
      await staged.publish();
    } on Object {
      await staged.discard();
      await _advanceJournal(journalId, 'failed');
      rethrow;
    }

    // Step 6 — publish metadata + advance journal in one transaction. Re-check
    // quota to close a concurrent race, and roll back the file on failure.
    try {
      return await unitOfWork.transaction((TransactionSession tx) async {
        final AttachmentWriteRepository writes = tx.repositories
            .resolve<AttachmentWriteRepository>();
        final AttachmentTotals txTotals = await writes.publishedTotals(
          request.profileId,
        );
        final AttachmentRejectionReason? reason = quota.check(
          fileBytes: plaintext.length,
          profileBytes: txTotals.bytes,
          profileCount: txTotals.count,
        );
        if (reason != null) {
          throw AttachmentRejected(reason);
        }
        final Attachment attachment = Attachment(
          id: request.attachmentId,
          profileId: request.profileId,
          noteId: request.noteId,
          displayName: request.displayName,
          declaredMime: request.declaredMime,
          detectedMime: detected.mime,
          byteSize: plaintext.length,
          contentHash: contentHash,
          wrappedDek: wrappedDek,
          cipherVersion: crypto.cipherVersion,
          pathToken: token,
          state: AttachmentState.published,
          createdAtUtc: _nowUtc,
          updatedAtUtc: _nowUtc,
        );
        await writes.insertPublished(attachment);
        await tx.repositories.resolve<FileJournalRepository>().advance(
          id: journalId,
          state: 'done',
          nowUtc: _nowUtc,
        );
        return attachment;
      });
    } on Object {
      await fileSystem.deleteManaged(token);
      await _advanceJournal(journalId, 'failed');
      rethrow;
    }
  }

  @override
  Future<AttachmentReadResult> readForPreview({
    required String profileId,
    required String attachmentId,
  }) async {
    final Attachment attachment = await _requirePublished(
      profileId: profileId,
      attachmentId: attachmentId,
    );
    final Uint8List plaintext = await _decrypt(attachment);
    return AttachmentReadResult(
      attachment: attachment,
      bytes: plaintext,
      safeForPreview: AttachmentTypePolicy.previewAllowlist.contains(
        attachment.detectedMime,
      ),
    );
  }

  @override
  Future<AttachmentExternalOpen> openExternally({
    required String profileId,
    required String attachmentId,
    required bool confirmed,
  }) async {
    if (!confirmed) {
      throw const AttachmentConfirmationRequired();
    }
    final Attachment attachment = await _requirePublished(
      profileId: profileId,
      attachmentId: attachmentId,
    );
    final Uint8List plaintext = await _decrypt(attachment);
    final ExternalTempFile temp = await fileSystem.writeExternalTemp(
      suggestedName: attachment.displayName,
      bytes: plaintext,
    );
    return AttachmentExternalOpen(attachment, temp.path, temp.dispose);
  }

  @override
  Future<void> deleteAttachment({
    required String profileId,
    required String attachmentId,
  }) async {
    final Attachment? attachment = await reads.find(
      profileId: profileId,
      attachmentId: attachmentId,
    );
    if (attachment == null || attachment.state == AttachmentState.deleted) {
      // Idempotent: nothing published to remove.
      return;
    }
    final String journalId = 'attach-delete-$attachmentId';

    // Journal the deletion and mark metadata deleted in one transaction, before
    // the file is removed, so a crash leaves a restart-safe cleanup record.
    await unitOfWork.transaction((TransactionSession tx) async {
      await tx.repositories.resolve<FileJournalRepository>().record(
        id: journalId,
        profileId: profileId,
        operation: _deleteOperation,
        state: 'in_progress',
        nowUtc: _nowUtc,
        ownerEntityType: _attachmentOwnerType,
        ownerEntityId: attachment.noteId,
        finalPathToken: attachment.pathToken,
      );
      await tx.repositories.resolve<AttachmentWriteRepository>().markDeleted(
        profileId: profileId,
        attachmentId: attachmentId,
        nowUtc: _nowUtc,
      );
    });

    await fileSystem.deleteManaged(attachment.pathToken);
    await _advanceJournal(journalId, 'cleaned');
  }

  Future<Uint8List> _readTrustedSource(String sourcePath) async {
    final OpenedSource source = await fileSystem.openSource(sourcePath);
    try {
      if (source.stat.type != SourceFileType.regular) {
        throw const AttachmentRejected(
          AttachmentRejectionReason.notRegularFile,
        );
      }
      final Uint8List bytes = await source.readAll();
      if (source.contentChangedSinceOpen) {
        throw const AttachmentRejected(
          AttachmentRejectionReason.sourceChangedDuringImport,
        );
      }
      if (bytes.isEmpty) {
        throw const AttachmentRejected(AttachmentRejectionReason.emptyFile);
      }
      return bytes;
    } finally {
      await source.close();
    }
  }

  Future<Attachment> _requirePublished({
    required String profileId,
    required String attachmentId,
  }) async {
    final Attachment? attachment = await reads.find(
      profileId: profileId,
      attachmentId: attachmentId,
    );
    if (attachment == null || attachment.state != AttachmentState.published) {
      throw AttachmentNotFound(attachmentId);
    }
    // Missing files never corrupt notes: surface as not-found without touching
    // any note state.
    if (!await fileSystem.managedExists(attachment.pathToken)) {
      throw AttachmentNotFound(attachmentId);
    }
    return attachment;
  }

  Future<Uint8List> _decrypt(Attachment attachment) async {
    final Uint8List ciphertext = await fileSystem.readManaged(
      attachment.pathToken,
    );
    final Uint8List dek = await _unwrapDek(attachment.wrappedDek);
    final Uint8List plaintext;
    try {
      plaintext = crypto.openContent(ciphertext: ciphertext, dek: dek);
    } finally {
      crypto.wipe(dek);
    }
    // Verify the pinned content hash (R-NOTE-006).
    if (crypto.contentHashHex(plaintext) != attachment.contentHash) {
      throw const AttachmentRejected(AttachmentRejectionReason.hashMismatch);
    }
    return plaintext;
  }

  Future<String> _wrapDek(Uint8List dek) async {
    final KeyLease lease = await keyVault.release();
    try {
      return crypto.wrapDek(dek: dek, kek: lease.copyBytes());
    } finally {
      await lease.dispose();
    }
  }

  Future<Uint8List> _unwrapDek(String wrappedDek) async {
    final KeyLease lease = await keyVault.release();
    try {
      return crypto.unwrapDek(wrappedDek: wrappedDek, kek: lease.copyBytes());
    } finally {
      await lease.dispose();
    }
  }

  Future<void> _advanceJournal(String journalId, String state) async {
    await unitOfWork.transaction((TransactionSession tx) async {
      await tx.repositories.resolve<FileJournalRepository>().advance(
        id: journalId,
        state: state,
        nowUtc: _nowUtc,
      );
    });
  }
}
