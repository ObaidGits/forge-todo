import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/notes/domain/attachments/attachment_quota.dart';
import 'package:forge/features/notes/domain/attachments/attachment_rejection.dart';

/// Hard storage-bound policy for managed attachments (task 10.3).
///
/// **Validates: Requirements R-NOTE-006**
void main() {
  const AttachmentQuota quota = AttachmentQuota(
    maxFileBytes: 1000,
    maxProfileBytes: 5000,
    maxFileCount: 3,
  );

  test('accepts a file that fits every bound', () {
    expect(
      quota.check(fileBytes: 500, profileBytes: 1000, profileCount: 1),
      isNull,
    );
  });

  test('rejects an empty file', () {
    expect(
      quota.check(fileBytes: 0, profileBytes: 0, profileCount: 0),
      AttachmentRejectionReason.emptyFile,
    );
  });

  test('rejects a file over the per-file ceiling', () {
    expect(
      quota.check(fileBytes: 1001, profileBytes: 0, profileCount: 0),
      AttachmentRejectionReason.perFileTooLarge,
    );
  });

  test('rejects when the count quota would be exceeded', () {
    expect(
      quota.check(fileBytes: 10, profileBytes: 0, profileCount: 3),
      AttachmentRejectionReason.countQuotaExceeded,
    );
  });

  test('rejects when the profile byte quota would be exceeded', () {
    expect(
      quota.check(fileBytes: 600, profileBytes: 4500, profileCount: 1),
      AttachmentRejectionReason.profileQuotaExceeded,
    );
  });

  test('enforce throws AttachmentRejected on the first failing bound', () {
    expect(
      () => quota.enforce(fileBytes: 2000, profileBytes: 0, profileCount: 0),
      throwsA(isA<AttachmentRejected>()),
    );
  });

  // Property: a file is accepted iff it is non-empty, within the per-file
  // ceiling, does not push the count over the limit, and does not push the
  // running byte total over the profile ceiling. No accepted file ever causes
  // the totals to exceed a bound.
  test('property: acceptance never lets totals exceed a bound', () {
    for (int seed = 0; seed < 500; seed += 1) {
      final Random random = Random(seed);
      final int fileBytes = random.nextInt(1400) - 100; // -100..1299
      final int profileBytes = random.nextInt(5200);
      final int profileCount = random.nextInt(5);

      final AttachmentRejectionReason? reason = quota.check(
        fileBytes: fileBytes,
        profileBytes: profileBytes,
        profileCount: profileCount,
      );

      final bool fits =
          fileBytes > 0 &&
          fileBytes <= quota.maxFileBytes &&
          profileCount + 1 <= quota.maxFileCount &&
          profileBytes + fileBytes <= quota.maxProfileBytes;

      expect(reason == null, fits, reason: 'seed=$seed');
      if (reason == null) {
        expect(profileBytes + fileBytes <= quota.maxProfileBytes, isTrue);
        expect(profileCount + 1 <= quota.maxFileCount, isTrue);
      }
    }
  });
}
