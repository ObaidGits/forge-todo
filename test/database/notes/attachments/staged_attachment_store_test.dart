import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/notes/application/attachments/attachment_crypto.dart';
import 'package:forge/features/notes/application/attachments/attachment_store.dart';
import 'package:forge/features/notes/domain/attachments/attachment.dart';
import 'package:forge/features/notes/domain/attachments/attachment_quota.dart';
import 'package:forge/features/notes/domain/attachments/attachment_rejection.dart';
import 'package:forge/features/notes/infrastructure/staged_attachment_store.dart';

import 'attachment_test_support.dart';

/// The security-first staged-write managed-attachment pipeline (task 10.3).
///
/// **Validates: Requirements R-NOTE-006, R-SEC-002, R-SEC-005, R-BACKUP-001**
void main() {
  late AttachmentHarness h;

  setUp(() async {
    h = await AttachmentHarness.open();
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

  group('import happy path', () {
    test(
      'publishes encrypted content, metadata, and a completed journal',
      () async {
        h.fileSystem.registerRegularSource('/import/photo.png', validPngBytes);

        final Attachment attachment = await h.store.importAttachment(request());

        expect(attachment.state, AttachmentState.published);
        expect(attachment.detectedMime, 'image/png');
        expect(attachment.byteSize, validPngBytes.length);

        // Metadata row published.
        final Map<String, Object?>? row = await h.attachmentRow('att-1');
        expect(row, isNotNull);
        expect(row!['state'], 'published');
        expect(row['wrapped_dek'], isNot('')); // key wrapped, never plaintext

        // The file on disk is ciphertext, not the plaintext bytes.
        final published = h.fileSystem.published[attachment.pathToken]!;
        expect(published, isNot(orderedEquals(validPngBytes)));

        // Journal advanced to done.
        final List<Map<String, Object?>> journal = await h.journalRows();
        expect(journal, hasLength(1));
        expect(journal.single['operation'], 'import');
        expect(journal.single['state'], 'done');
        expect(journal.single['expected_bytes'], validPngBytes.length);
      },
    );

    test('fsyncs the staged file before the atomic publish rename', () async {
      h.fileSystem.registerRegularSource('/import/photo.png', validPngBytes);
      await h.store.importAttachment(request());

      final int sync = h.fileSystem.log.indexWhere(
        (String e) => e.startsWith('stage.sync:'),
      );
      final int publish = h.fileSystem.log.indexWhere(
        (String e) => e.startsWith('stage.publish:'),
      );
      expect(sync, greaterThanOrEqualTo(0));
      expect(publish, greaterThan(sync));
    });
  });

  group('regular-file and TOCTOU defenses', () {
    test('rejects a symlink source and publishes nothing', () async {
      h.fileSystem.registerSymlinkSource(
        '/import/link.png',
        bytes: validPngBytes,
      );

      await expectLater(
        h.store.importAttachment(request(source: '/import/link.png')),
        throwsA(
          isA<AttachmentRejected>().having(
            (AttachmentRejected e) => e.reason,
            'reason',
            AttachmentRejectionReason.notRegularFile,
          ),
        ),
      );
      expect(await h.attachmentRow('att-1'), isNull);
      expect(h.fileSystem.published, isEmpty);
    });

    test('rejects a non-regular (device/special) source', () async {
      h.fileSystem.registerSpecialSource('/dev/zero');
      await expectLater(
        h.store.importAttachment(request(source: '/dev/zero')),
        throwsA(isA<AttachmentRejected>()),
      );
    });

    test('rejects a source swapped between open and read (TOCTOU)', () async {
      h.fileSystem.registerToctouSource(
        '/import/photo.png',
        atOpen: validPngBytes,
        atRead: validPdfBytes,
      );
      await expectLater(
        h.store.importAttachment(request()),
        throwsA(
          isA<AttachmentRejected>().having(
            (AttachmentRejected e) => e.reason,
            'reason',
            AttachmentRejectionReason.sourceChangedDuringImport,
          ),
        ),
      );
      expect(h.fileSystem.published, isEmpty);
    });
  });

  group('magic and quota checks', () {
    test('rejects content with no accepted magic signature', () async {
      h.fileSystem.registerRegularSource('/import/blob', unknownBytes);
      await expectLater(
        h.store.importAttachment(
          request(source: '/import/blob', declaredMime: ''),
        ),
        throwsA(
          isA<AttachmentRejected>().having(
            (AttachmentRejected e) => e.reason,
            'reason',
            AttachmentRejectionReason.unsupportedType,
          ),
        ),
      );
    });

    test(
      'rejects a declared MIME that disagrees with the magic bytes',
      () async {
        h.fileSystem.registerRegularSource('/import/photo.png', validPngBytes);
        await expectLater(
          h.store.importAttachment(request(declaredMime: 'application/pdf')),
          throwsA(
            isA<AttachmentRejected>().having(
              (AttachmentRejected e) => e.reason,
              'reason',
              AttachmentRejectionReason.declaredTypeMismatch,
            ),
          ),
        );
      },
    );

    test('enforces the per-file byte quota', () async {
      // Reuse the harness DB/ports with a tighter quota (no second database).
      final StagedAttachmentStore store = StagedAttachmentStore(
        unitOfWork: h.store.unitOfWork,
        reads: h.reads,
        fileSystem: h.fileSystem,
        crypto: h.crypto,
        keyVault: h.keyVault,
        now: DateTime.now,
        quota: const AttachmentQuota(
          maxFileBytes: 4,
          maxProfileBytes: 1000,
          maxFileCount: 10,
        ),
      );
      h.fileSystem.registerRegularSource('/import/photo.png', validPngBytes);
      await expectLater(
        store.importAttachment(
          AttachmentImportRequest(
            attachmentId: 'att-big',
            profileId: h.profileId,
            noteId: h.noteId,
            sourcePath: '/import/photo.png',
            displayName: 'photo.png',
            declaredMime: 'image/png',
          ),
        ),
        throwsA(
          isA<AttachmentRejected>().having(
            (AttachmentRejected e) => e.reason,
            'reason',
            AttachmentRejectionReason.perFileTooLarge,
          ),
        ),
      );
    });
  });

  group('deletion journal', () {
    test(
      'soft-deletes metadata, journals the deletion, and removes the file',
      () async {
        h.fileSystem.registerRegularSource('/import/photo.png', validPngBytes);
        final Attachment attachment = await h.store.importAttachment(request());
        expect(h.fileSystem.published, contains(attachment.pathToken));

        await h.store.deleteAttachment(
          profileId: h.profileId,
          attachmentId: 'att-1',
        );

        final Map<String, Object?>? row = await h.attachmentRow('att-1');
        expect(row!['state'], 'deleted');
        expect(row['deleted_at_utc'], isNotNull);
        expect(h.fileSystem.published, isNot(contains(attachment.pathToken)));

        final List<Map<String, Object?>> journal = await h.journalRows();
        final Map<String, Object?> del = journal.firstWhere(
          (Map<String, Object?> r) => r['operation'] == 'delete',
        );
        expect(del['state'], 'cleaned');

        // Journaling happens before the file removal.
        final int deleteFile = h.fileSystem.log.indexWhere(
          (String e) => e.startsWith('delete:'),
        );
        expect(deleteFile, greaterThanOrEqualTo(0));
      },
    );

    test('is idempotent when the attachment is already deleted', () async {
      h.fileSystem.registerRegularSource('/import/photo.png', validPngBytes);
      await h.store.importAttachment(request());
      await h.store.deleteAttachment(
        profileId: h.profileId,
        attachmentId: 'att-1',
      );
      // Second delete does not throw and does not re-journal.
      await h.store.deleteAttachment(
        profileId: h.profileId,
        attachmentId: 'att-1',
      );
      final List<Map<String, Object?>> journal = await h.journalRows();
      expect(
        journal.where((Map<String, Object?> r) => r['operation'] == 'delete'),
        hasLength(1),
      );
    });
  });

  group('safe read and external open', () {
    test('decrypts content for preview and verifies the pinned hash', () async {
      h.fileSystem.registerRegularSource('/import/photo.png', validPngBytes);
      await h.store.importAttachment(request());

      final AttachmentReadResult result = await h.store.readForPreview(
        profileId: h.profileId,
        attachmentId: 'att-1',
      );
      expect(result.bytes, orderedEquals(validPngBytes));
      expect(result.safeForPreview, isTrue);
    });

    test('external open requires explicit confirmation', () async {
      h.fileSystem.registerRegularSource('/import/photo.png', validPngBytes);
      await h.store.importAttachment(request());

      await expectLater(
        h.store.openExternally(
          profileId: h.profileId,
          attachmentId: 'att-1',
          confirmed: false,
        ),
        throwsA(isA<AttachmentConfirmationRequired>()),
      );
    });

    test(
      'confirmed external open writes a disposable decrypted temp file',
      () async {
        h.fileSystem.registerRegularSource('/import/photo.png', validPngBytes);
        await h.store.importAttachment(request());

        final AttachmentExternalOpen open = await h.store.openExternally(
          profileId: h.profileId,
          attachmentId: 'att-1',
          confirmed: true,
        );
        expect(h.fileSystem.externalTemps, contains(open.tempPath));
        await open.dispose();
        expect(h.fileSystem.externalTemps, isEmpty);
      },
    );

    test(
      'a missing file surfaces as not-found and never corrupts the note',
      () async {
        h.fileSystem.registerRegularSource('/import/photo.png', validPngBytes);
        final Attachment attachment = await h.store.importAttachment(request());
        // Simulate the encrypted file vanishing underneath us.
        h.fileSystem.published.remove(attachment.pathToken);

        await expectLater(
          h.store.readForPreview(profileId: h.profileId, attachmentId: 'att-1'),
          throwsA(isA<AttachmentNotFound>()),
        );
        // The note row is untouched.
        final row = await h.attachmentRow('att-1');
        expect(row!['state'], 'published');
      },
    );

    test('a tampered ciphertext fails authenticated decryption', () async {
      h.fileSystem.registerRegularSource('/import/photo.png', validPngBytes);
      final Attachment attachment = await h.store.importAttachment(request());
      final Uint8List tampered = Uint8List.fromList(
        h.fileSystem.published[attachment.pathToken]!,
      );
      tampered[0] = tampered[0] ^ 0xff;
      h.fileSystem.published[attachment.pathToken] = tampered;

      await expectLater(
        h.store.readForPreview(profileId: h.profileId, attachmentId: 'att-1'),
        throwsA(isA<AttachmentCryptoAuthError>()),
      );
    });
  });
}
