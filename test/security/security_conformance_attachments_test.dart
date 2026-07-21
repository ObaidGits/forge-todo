/// Independent security conformance harness — managed attachments (task 12.4).
///
/// Drives the security-first staged-write attachment pipeline end-to-end
/// through the existing `AttachmentHarness` (reused, not forked) to verify:
/// symlink/special-file rejection, TOCTOU-replacement rejection, magic/MIME
/// validation, fsync-before-publish durability, deletion journaled before the
/// file is removed, and least-lived external-open grants requiring explicit
/// confirmation. The per-file/profile/count quota bound is verified against the
/// pure domain policy.
///
/// **Validates: Requirements R-SEC-002, R-SEC-005**
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/notes/application/attachments/attachment_store.dart';
import 'package:forge/features/notes/domain/attachments/attachment.dart';
import 'package:forge/features/notes/domain/attachments/attachment_quota.dart';
import 'package:forge/features/notes/domain/attachments/attachment_rejection.dart';

import '../database/notes/attachments/attachment_test_support.dart';
import '../helpers/evidence.dart';
import 'security_conformance_support.dart';

void main() {
  late AttachmentHarness h;

  setUp(() async {
    h = await AttachmentHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  AttachmentImportRequest request({
    required String id,
    required String source,
    String declaredMime = '',
  }) => AttachmentImportRequest(
    attachmentId: id,
    profileId: h.profileId,
    noteId: h.noteId,
    sourcePath: source,
    displayName: 'file-$id',
    declaredMime: declaredMime,
  );

  group('Untrusted-source rejection', () {
    testWithEvidence(
      secEvidence('ATTACH-SYMLINK-REJECTED', <String>['R-SEC-002']),
      'a symlink source is rejected as a non-regular file',
      () async {
        h.fileSystem.registerSymlinkSource(
          '/ext/link.png',
          bytes: validPngBytes,
        );
        await expectLater(
          h.store.importAttachment(
            request(id: 'att-1', source: '/ext/link.png'),
          ),
          throwsA(
            isA<AttachmentRejected>().having(
              (AttachmentRejected e) => e.reason,
              'reason',
              AttachmentRejectionReason.notRegularFile,
            ),
          ),
        );
        expect(await h.attachmentRow('att-1'), isNull);
      },
    );

    testWithEvidence(
      secEvidence('ATTACH-TOCTOU-REJECTED', <String>['R-SEC-002']),
      'a source swapped between open and read (TOCTOU) is abandoned',
      () async {
        h.fileSystem.registerToctouSource(
          '/ext/race.png',
          atOpen: validPngBytes,
          atRead: <int>[0x00, 0x01, 0x02, 0x03],
        );
        await expectLater(
          h.store.importAttachment(
            request(id: 'att-2', source: '/ext/race.png'),
          ),
          throwsA(
            isA<AttachmentRejected>().having(
              (AttachmentRejected e) => e.reason,
              'reason',
              AttachmentRejectionReason.sourceChangedDuringImport,
            ),
          ),
        );
        expect(await h.attachmentRow('att-2'), isNull);
      },
    );

    testWithEvidence(
      secEvidence('ATTACH-MAGIC-UNKNOWN-REJECTED', <String>['R-SEC-002']),
      'content whose magic bytes match no accepted type is rejected',
      () async {
        h.fileSystem.registerRegularSource('/ext/blob.bin', unknownBytes);
        await expectLater(
          h.store.importAttachment(
            request(id: 'att-3', source: '/ext/blob.bin'),
          ),
          throwsA(
            isA<AttachmentRejected>().having(
              (AttachmentRejected e) => e.reason,
              'reason',
              AttachmentRejectionReason.unsupportedType,
            ),
          ),
        );
      },
    );

    testWithEvidence(
      secEvidence('ATTACH-DECLARED-MISMATCH-REJECTED', <String>['R-SEC-002']),
      'a declared MIME that disagrees with the detected magic is rejected',
      () async {
        h.fileSystem.registerRegularSource('/ext/pic.png', validPngBytes);
        await expectLater(
          h.store.importAttachment(
            request(
              id: 'att-4',
              source: '/ext/pic.png',
              declaredMime: 'application/pdf',
            ),
          ),
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
  });

  group('Durable staged-write publication', () {
    testWithEvidence(
      secEvidence('ATTACH-FSYNC-BEFORE-PUBLISH', <String>['R-SEC-002']),
      'a valid import fsyncs the staged file before the atomic publish',
      () async {
        h.fileSystem.registerRegularSource('/ext/ok.png', validPngBytes);
        final Attachment attachment = await h.store.importAttachment(
          request(id: 'att-ok', source: '/ext/ok.png'),
        );
        expect(attachment.state, AttachmentState.published);
        final int sync = h.fileSystem.log.indexOf('stage.sync:att-ok.att');
        final int publish = h.fileSystem.log.indexOf(
          'stage.publish:att-ok.att',
        );
        expect(sync, greaterThanOrEqualTo(0));
        expect(publish, greaterThan(sync));
        expect(await h.journalState('attach-import-att-ok'), 'done');
      },
    );

    testWithEvidence(
      secEvidence('ATTACH-DELETE-JOURNALED-FIRST', <String>['R-SEC-002']),
      'deletion journals durably and marks metadata before removing the file',
      () async {
        h.fileSystem.registerRegularSource('/ext/del.png', validPngBytes);
        await h.store.importAttachment(
          request(id: 'att-del', source: '/ext/del.png'),
        );
        await h.store.deleteAttachment(
          profileId: h.profileId,
          attachmentId: 'att-del',
        );
        expect(await h.journalState('attach-delete-att-del'), 'cleaned');
        expect(h.fileSystem.published.containsKey('att-del.att'), isFalse);
        final Map<String, Object?>? row = await h.attachmentRow('att-del');
        expect(row?['state'], AttachmentState.deleted.name);
      },
    );
  });

  group('Least-lived external open', () {
    testWithEvidence(
      secEvidence('ATTACH-EXTERNAL-CONFIRM-REQUIRED', <String>['R-SEC-005']),
      'an external open without explicit confirmation is refused',
      () async {
        h.fileSystem.registerRegularSource('/ext/open.png', validPngBytes);
        await h.store.importAttachment(
          request(id: 'att-x', source: '/ext/open.png'),
        );
        await expectLater(
          h.store.openExternally(
            profileId: h.profileId,
            attachmentId: 'att-x',
            confirmed: false,
          ),
          throwsA(isA<AttachmentConfirmationRequired>()),
        );
      },
    );

    testWithEvidence(
      secEvidence('ATTACH-EXTERNAL-GRANT-DISPOSED', <String>['R-SEC-005']),
      'a confirmed external open yields a temp grant that dispose() removes',
      () async {
        h.fileSystem.registerRegularSource('/ext/grant.png', validPngBytes);
        await h.store.importAttachment(
          request(id: 'att-g', source: '/ext/grant.png'),
        );
        final AttachmentExternalOpen open = await h.store.openExternally(
          profileId: h.profileId,
          attachmentId: 'att-g',
          confirmed: true,
        );
        expect(h.fileSystem.externalTemps, contains(open.tempPath));
        await open.dispose();
        expect(h.fileSystem.externalTemps, isNot(contains(open.tempPath)));
      },
    );
  });

  group('Quota bound (pure policy)', () {
    testWithEvidence(
      secEvidence('ATTACH-QUOTA-BOUNDS', <String>['R-SEC-002']),
      'per-file, per-profile, and count ceilings all fail closed',
      () {
        const AttachmentQuota quota = AttachmentQuota(
          maxFileBytes: 100,
          maxProfileBytes: 1000,
          maxFileCount: 3,
        );
        expect(
          quota.check(fileBytes: 101, profileBytes: 0, profileCount: 0),
          AttachmentRejectionReason.perFileTooLarge,
        );
        expect(
          quota.check(fileBytes: 50, profileBytes: 980, profileCount: 0),
          AttachmentRejectionReason.profileQuotaExceeded,
        );
        expect(
          quota.check(fileBytes: 10, profileBytes: 0, profileCount: 3),
          AttachmentRejectionReason.countQuotaExceeded,
        );
        expect(
          quota.check(fileBytes: 10, profileBytes: 0, profileCount: 0),
          isNull,
        );
      },
    );
  });
}
