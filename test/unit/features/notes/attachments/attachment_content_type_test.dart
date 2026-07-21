import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/notes/domain/attachments/attachment_content_type.dart';
import 'package:forge/features/notes/domain/attachments/attachment_rejection.dart';

/// Magic-byte content-type detection and the accepted-type policy for managed
/// attachments (task 10.3).
///
/// **Validates: Requirements R-NOTE-006, R-SEC-002**
void main() {
  const AttachmentTypePolicy policy = AttachmentTypePolicy();

  final Map<String, List<int>> signatures = <String, List<int>>{
    'image/png': <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
    'image/jpeg': <int>[0xff, 0xd8, 0xff, 0xe0],
    'image/gif': <int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61],
    'application/pdf': <int>[0x25, 0x50, 0x44, 0x46, 0x2d, 0x31],
    'image/webp': <int>[
      0x52, 0x49, 0x46, 0x46, 0x10, 0x00, 0x00, 0x00, //
      0x57, 0x45, 0x42, 0x50,
    ],
  };

  group('detect', () {
    signatures.forEach((String mime, List<int> header) {
      test('detects $mime from its magic bytes', () {
        expect(policy.detect(header)?.mime, mime);
      });
    });

    test('returns null for content with no recognised signature', () {
      expect(policy.detect(<int>[0, 1, 2, 3, 4, 5, 6, 7]), isNull);
    });

    test('does not misread PNG when the header is truncated', () {
      expect(policy.detect(<int>[0x89, 0x50]), isNull);
    });
  });

  group('validate', () {
    test('accepts content whose declared MIME matches the detected type', () {
      final DetectedContentType detected = policy.validate(
        header: signatures['image/png']!,
        declaredMime: 'image/png',
      );
      expect(detected.mime, 'image/png');
      expect(detected.safeForPreview, isTrue);
    });

    test('accepts an empty declared MIME (trusts the content)', () {
      expect(
        policy
            .validate(header: signatures['image/jpeg']!, declaredMime: '')
            .mime,
        'image/jpeg',
      );
    });

    test('rejects a declared MIME that lies about the content', () {
      expect(
        () => policy.validate(
          header: signatures['image/png']!,
          declaredMime: 'application/pdf',
        ),
        throwsA(
          isA<AttachmentRejected>().having(
            (AttachmentRejected e) => e.reason,
            'reason',
            AttachmentRejectionReason.declaredTypeMismatch,
          ),
        ),
      );
    });

    test('rejects an unsupported content type', () {
      expect(
        () => policy.validate(
          header: <int>[0x4d, 0x5a, 0x90, 0x00], // MZ (executable)
          declaredMime: '',
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
  });

  // Property: for every accepted signature with arbitrary trailing bytes, the
  // detected type is stable and matches the declared MIME check, while random
  // non-signature prefixes are never accepted. This defends the preview
  // allowlist against content that lies about its type.
  test('property: detection is signature-driven and declaration-consistent', () {
    for (int seed = 0; seed < 200; seed += 1) {
      final Random random = Random(seed);
      final List<String> mimes = signatures.keys.toList();
      final String mime = mimes[random.nextInt(mimes.length)];
      final List<int> header = <int>[
        ...signatures[mime]!,
        for (int i = 0; i < random.nextInt(8); i += 1) random.nextInt(256),
      ];
      final DetectedContentType detected = policy.validate(
        header: header,
        declaredMime: random.nextBool() ? mime : '',
      );
      expect(detected.mime, mime);
      expect(
        detected.safeForPreview,
        AttachmentTypePolicy.previewAllowlist.contains(mime),
      );

      // A random 4-byte prefix that is not a known signature is never accepted.
      final List<int> noise = <int>[
        // Force a first byte that no signature starts with.
        0x01,
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
      ];
      expect(policy.detect(noise), isNull);
    }
  });
}
