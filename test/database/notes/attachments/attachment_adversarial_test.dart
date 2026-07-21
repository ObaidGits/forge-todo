import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/notes/application/attachments/attachment_crypto.dart';
import 'package:forge/features/notes/application/attachments/attachment_store.dart';
import 'package:forge/features/notes/domain/attachments/attachment.dart';
import 'package:forge/features/notes/domain/attachments/attachment_quota.dart';
import 'package:forge/features/notes/domain/attachments/attachment_rejection.dart';
import 'package:forge/features/notes/infrastructure/attachment_backup_codec.dart';
import 'package:forge/features/notes/infrastructure/attachment_journal_recovery.dart';
import 'package:forge/features/notes/infrastructure/staged_attachment_store.dart';

import '../../../helpers/fake_attachment_crypto.dart';
import '../../../helpers/fake_key_vault.dart';
import 'attachment_test_support.dart';

/// Wave 9 risk-gate adversarial depth for managed attachments (task 10.8).
///
/// The core defenses (symlink/TOCTOU rejection, magic/MIME, per-file quota,
/// deletion journal, safe read/open) are exercised by
/// `staged_attachment_store_test.dart` (task 10.3). This suite adds the
/// adversarial and crash-injection depth testing.md §5/§13 require: sparse-file
/// size trust, profile/count quota, cross-device key portability, and durable
/// file-journal recovery after a crash at each of stage/publish/delete.
///
/// MANUAL-* follow-ups (real OS/device only; deliberately NOT faked here):
///  * MANUAL-ATTACH-SYMLINK-FS — symlink/hardlink and non-regular source
///    rejection against a real filesystem; the port models opened-descriptor
///    fstat here, the dart:io adapter needs a real FS.
///  * MANUAL-ATTACH-TOCTOU-FS — a genuine time-of-check/time-of-use source swap
///    on a real filesystem under concurrent writers.
///  * MANUAL-ATTACH-BIOMETRIC-KEK — key portability where the device KEK is
///    gated by biometric/secure-enclave hardware on a physical device.
///
/// **Validates: Requirements R-NOTE-006, NFR-REL-002**
void main() {
  late AttachmentHarness h;

  // Known device KEK so the cross-device portability test can rewrap.
  const List<int> kekA = <int>[1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144];

  setUp(() async {
    h = await AttachmentHarness.open(kek: kekA);
  });

  tearDown(() async {
    await h.close();
  });

  AttachmentImportRequest request({
    String id = 'att-1',
    String source = '/import/photo.png',
    String declaredMime = 'image/png',
    String displayName = 'photo.png',
  }) => AttachmentImportRequest(
    attachmentId: id,
    profileId: h.profileId,
    noteId: h.noteId,
    sourcePath: source,
    displayName: displayName,
    declaredMime: declaredMime,
  );

  group(
    '[TEST-ATTACH-SPARSE][V1][TASK-10.8][R-NOTE-006] sparse-file handling',
    () {
      test(
        'a source that stats huge but streams a small valid file is quota-checked '
        'on the true streamed bytes, not the stat size',
        () async {
          // stat reports 10 GiB (a hole-punched sparse file) but only a small
          // valid PNG actually streams out.
          h.fileSystem.registerSparseSource(
            '/import/sparse.png',
            statSize: 10 * 1024 * 1024 * 1024,
            bytes: validPngBytes,
          );

          final Attachment attachment = await h.store.importAttachment(
            request(source: '/import/sparse.png'),
          );

          // Published: the quota trusted the real content bytes, not the stat.
          expect(attachment.state, AttachmentState.published);
          expect(attachment.byteSize, validPngBytes.length);
        },
      );

      test(
        'a source that stats small but streams bytes over the per-file quota is '
        'rejected on the true streamed byte count',
        () async {
          final Uint8List big = Uint8List(64)
            ..setRange(0, validPngBytes.length, validPngBytes);
          // The stat lies (claims 8 bytes) while 64 bytes actually stream out.
          h.fileSystem.registerSparseSource(
            '/import/liar.png',
            statSize: 8,
            bytes: big,
          );
          final StagedAttachmentStore store = StagedAttachmentStore(
            unitOfWork: h.store.unitOfWork,
            reads: h.reads,
            fileSystem: h.fileSystem,
            crypto: h.crypto,
            keyVault: h.keyVault,
            now: DateTime.now,
            quota: const AttachmentQuota(
              maxFileBytes: 32,
              maxProfileBytes: 100000,
              maxFileCount: 100,
            ),
          );

          await expectLater(
            store.importAttachment(request(source: '/import/liar.png')),
            throwsA(
              isA<AttachmentRejected>().having(
                (AttachmentRejected e) => e.reason,
                'reason',
                AttachmentRejectionReason.perFileTooLarge,
              ),
            ),
          );
          expect(h.fileSystem.published, isEmpty);
        },
      );
    },
  );

  group(
    '[TEST-ATTACH-QUOTA][V1][TASK-10.8][R-NOTE-006] profile and count quota',
    () {
      test('enforces the per-profile byte quota against live totals', () async {
        // A quota large enough for one file but not two.
        final StagedAttachmentStore store = StagedAttachmentStore(
          unitOfWork: h.store.unitOfWork,
          reads: h.reads,
          fileSystem: h.fileSystem,
          crypto: h.crypto,
          keyVault: h.keyVault,
          now: DateTime.now,
          quota: AttachmentQuota(
            maxFileBytes: 1000,
            maxProfileBytes: validPngBytes.length + 4,
            maxFileCount: 100,
          ),
        );
        h.fileSystem.registerRegularSource('/import/a.png', validPngBytes);
        h.fileSystem.registerRegularSource('/import/b.png', validPngBytes);

        await store.importAttachment(
          request(id: 'att-a', source: '/import/a.png'),
        );
        // The second import would push the profile over its byte ceiling.
        await expectLater(
          store.importAttachment(request(id: 'att-b', source: '/import/b.png')),
          throwsA(
            isA<AttachmentRejected>().having(
              (AttachmentRejected e) => e.reason,
              'reason',
              AttachmentRejectionReason.profileQuotaExceeded,
            ),
          ),
        );
        // The rejected import left no orphaned published file.
        expect(h.fileSystem.published, hasLength(1));
      });

      test('enforces the per-profile file-count quota', () async {
        final StagedAttachmentStore store = StagedAttachmentStore(
          unitOfWork: h.store.unitOfWork,
          reads: h.reads,
          fileSystem: h.fileSystem,
          crypto: h.crypto,
          keyVault: h.keyVault,
          now: DateTime.now,
          quota: const AttachmentQuota(
            maxFileBytes: 1000,
            maxProfileBytes: 1000000,
            maxFileCount: 1,
          ),
        );
        h.fileSystem.registerRegularSource('/import/a.png', validPngBytes);
        h.fileSystem.registerRegularSource('/import/b.png', validPngBytes);

        await store.importAttachment(
          request(id: 'att-a', source: '/import/a.png'),
        );
        await expectLater(
          store.importAttachment(request(id: 'att-b', source: '/import/b.png')),
          throwsA(
            isA<AttachmentRejected>().having(
              (AttachmentRejected e) => e.reason,
              'reason',
              AttachmentRejectionReason.countQuotaExceeded,
            ),
          ),
        );
      });
    },
  );

  group('[TEST-ATTACH-KEY-PORTABILITY][V1][TASK-10.8][R-NOTE-006] '
      'cross-device key portability', () {
    test('a different device KEK cannot read an attachment until its DEK is '
        'rewrapped; after rewrap the content is portable', () async {
      h.fileSystem.registerRegularSource('/import/photo.png', validPngBytes);
      final Attachment attachment = await h.store.importAttachment(request());

      // Device B: the same encrypted store and files but a different KEK.
      const List<int> kekB = <int>[9, 9, 9, 9, 8, 8, 8, 8, 7, 7, 7, 7];
      final StagedAttachmentStore deviceB = StagedAttachmentStore(
        unitOfWork: h.store.unitOfWork,
        reads: h.reads,
        fileSystem: h.fileSystem,
        crypto: FakeAttachmentCrypto(),
        keyVault: FakeKeyVault.available(kekB),
        now: DateTime.now,
      );

      // Without rewrapping, device B's KEK cannot unwrap the per-file DEK.
      await expectLater(
        deviceB.readForPreview(profileId: h.profileId, attachmentId: 'att-1'),
        throwsA(isA<AttachmentCryptoAuthError>()),
      );

      // Rewrap the stored DEK for backup then onto device B's KEK, exactly as
      // a Forge-backup restore onto a new device does.
      const List<int> backupKey = <int>[3, 1, 4, 1, 5, 9, 2, 6];
      final AttachmentBackupCodec codec = AttachmentBackupCodec(h.crypto);
      final String backupWrapped = codec.rewrapForBackup(
        wrappedDek: attachment.wrappedDek,
        kek: kekA,
        backupKey: backupKey,
      );
      final String deviceBWrapped = codec.rewrapOnRestore(
        backupWrappedDek: backupWrapped,
        backupKey: backupKey,
        kek: kekB,
      );
      await h.db.customStatement(
        'UPDATE attachments SET wrapped_dek = ? WHERE id = ?',
        <Object?>[deviceBWrapped, 'att-1'],
      );

      // Now device B decrypts the very same ciphertext to the original bytes.
      final AttachmentReadResult result = await deviceB.readForPreview(
        profileId: h.profileId,
        attachmentId: 'att-1',
      );
      expect(result.bytes, orderedEquals(validPngBytes));
    });
  });

  group('[TEST-ATTACH-CRASH][V1][TASK-10.8][R-NOTE-006,NFR-REL-002] '
      'crash-injection and durable journal recovery', () {
    AttachmentJournalRecovery recovery() => AttachmentJournalRecovery(
      db: h.db,
      unitOfWork: h.store.unitOfWork,
      fileSystem: h.fileSystem,
      now: () => DateTime.utc(2024, 6, 2),
    );

    test('a crash during publish leaves no metadata, no orphaned file, and a '
        'failed journal (in-process cleanup)', () async {
      h.fileSystem.registerRegularSource('/import/photo.png', validPngBytes);
      h.fileSystem.failPublish = true;

      await expectLater(
        h.store.importAttachment(request()),
        throwsA(isA<StateError>()),
      );

      expect(await h.attachmentRow('att-1'), isNull);
      expect(h.fileSystem.published, isEmpty);
      final Map<String, Object?> journal = (await h.journalRows()).single;
      expect(journal['operation'], 'import');
      expect(journal['state'], 'failed');
    });

    test('recovery removes an orphaned staged/published file left by a crash '
        'between publish and metadata commit, and fails its journal', () async {
      // Reconstruct the post-crash on-disk state: an in-flight import journal
      // and a published file with NO committed attachment metadata.
      const String token = 'att-orphan.att';
      h.fileSystem.published[token] = Uint8List.fromList(validPngBytes);
      await h.recordJournal(
        id: 'attach-import-att-orphan',
        operation: 'import',
        state: 'in_progress',
        token: token,
      );

      final AttachmentRecoveryReport report = await recovery().recover(
        h.profileId,
      );

      expect(report.failedImports, 1);
      expect(h.fileSystem.published, isNot(contains(token)));
      expect(await h.journalState('attach-import-att-orphan'), 'failed');
    });

    test('recovery leaves a committed published import intact and only '
        'finalizes its journal to done', () async {
      h.fileSystem.registerRegularSource('/import/photo.png', validPngBytes);
      final Attachment attachment = await h.store.importAttachment(request());
      // Simulate a crash in the narrow window after the metadata commit but
      // before the journal advance: force the journal back to in_progress.
      await h.setJournalState('attach-import-att-1', 'in_progress');

      final AttachmentRecoveryReport report = await recovery().recover(
        h.profileId,
      );

      expect(report.reconciledPublished, 1);
      expect(report.failedImports, 0);
      // The live file is untouched and the metadata is still published.
      expect(h.fileSystem.published, contains(attachment.pathToken));
      expect((await h.attachmentRow('att-1'))!['state'], 'published');
      expect(await h.journalState('attach-import-att-1'), 'done');
    });

    test(
      'a crash during deletion (after journaling, before file removal) is '
      'completed by recovery: the file is removed and the journal cleaned',
      () async {
        h.fileSystem.registerRegularSource('/import/photo.png', validPngBytes);
        final Attachment attachment = await h.store.importAttachment(request());

        // The file removal crashes; the delete is journaled and metadata marked
        // deleted, but the file is still on disk.
        h.fileSystem.failDelete = true;
        await expectLater(
          h.store.deleteAttachment(
            profileId: h.profileId,
            attachmentId: 'att-1',
          ),
          throwsA(isA<StateError>()),
        );
        expect(h.fileSystem.published, contains(attachment.pathToken));
        expect(await h.journalState('attach-delete-att-1'), 'in_progress');

        // Recovery completes the interrupted deletion.
        h.fileSystem.failDelete = false;
        final AttachmentRecoveryReport report = await recovery().recover(
          h.profileId,
        );
        expect(report.completedDeletions, 1);
        expect(h.fileSystem.published, isNot(contains(attachment.pathToken)));
        expect(await h.journalState('attach-delete-att-1'), 'cleaned');
      },
    );

    test('the recovery sweep is idempotent: a second run is a no-op', () async {
      const String token = 'att-orphan-2.att';
      h.fileSystem.published[token] = Uint8List.fromList(validPngBytes);
      await h.recordJournal(
        id: 'attach-import-att-orphan-2',
        operation: 'import',
        state: 'in_progress',
        token: token,
      );

      await recovery().recover(h.profileId);
      final AttachmentRecoveryReport second = await recovery().recover(
        h.profileId,
      );
      expect(second.isEmpty, isTrue);
    });
  });
}
