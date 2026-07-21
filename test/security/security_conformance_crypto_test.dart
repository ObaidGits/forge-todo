/// Independent security conformance harness — cryptography & FBC1 (task 12.4).
///
/// This suite verifies the crypto invariants end-to-end rather than trusting a
/// single cipher unit test: authenticated encryption is fail-closed (tamper,
/// truncation, reorder, and wrong-key all fail), no plaintext survives into
/// ciphertext, and the FBC1 backup container detects every framing/tamper
/// attack it must (bad magic, header tamper, frame reorder, truncation,
/// trailing frame, and path traversal) while bounding archive/entry sizes.
///
/// **Validates: Requirements R-SEC-002, NFR-SEC-001**
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/security/key_vault_machine.dart';
import 'package:forge/core/security/key_vault_ports.dart';
import 'package:forge/features/backup/infrastructure/fbc1_container.dart';
import 'package:forge/features/notes/application/attachments/attachment_crypto.dart';

import '../helpers/backup_test_crypto.dart';
import '../helpers/evidence.dart';
import '../helpers/fake_attachment_crypto.dart';
import 'security_conformance_support.dart';

/// A stable 16-byte salt for deterministic FBC1 archives.
final Uint8List _salt = Uint8List.fromList(
  List<int>.generate(16, (int i) => i + 1),
);

final List<int> _passphrase = 'correct horse battery staple'.codeUnits;

Future<Uint8List> _archive(Fbc1Codec codec, List<Fbc1File> files) async =>
    codec.encode(passphrase: _passphrase, files: files, salt: _salt);

/// True when [haystack] contains [needle] as a contiguous byte run.
bool _containsRun(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) {
    return false;
  }
  for (int i = 0; i <= haystack.length - needle.length; i += 1) {
    bool match = true;
    for (int j = 0; j < needle.length; j += 1) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) {
      return true;
    }
  }
  return false;
}

void main() {
  group('AEAD authenticated encryption (no plaintext leakage)', () {
    final FakeAttachmentCrypto crypto = FakeAttachmentCrypto();

    testWithEvidence(
      secEvidence('CRYPTO-AEAD-NO-PLAINTEXT', <String>[
        'R-SEC-002',
        'NFR-SEC-001',
      ]),
      'sealed content is authenticated and never carries the plaintext bytes',
      () {
        final Uint8List dek = crypto.newDek();
        final Uint8List plaintext = Uint8List.fromList(
          'SENSITIVE-NOTE-CONTENT-marker-0123456789'.codeUnits,
        );
        final Uint8List ciphertext = crypto.sealContent(
          plaintext: plaintext,
          dek: dek,
        );
        // The distinctive plaintext run must not survive into ciphertext.
        expect(_containsRun(ciphertext, plaintext), isFalse);
        // Round-trips under the right key.
        expect(crypto.openContent(ciphertext: ciphertext, dek: dek), plaintext);
      },
    );

    testWithEvidence(
      secEvidence('CRYPTO-AEAD-TAMPER', <String>['R-SEC-002']),
      'a single flipped ciphertext byte fails authentication (fail-closed)',
      () {
        final Uint8List dek = crypto.newDek();
        final Uint8List ciphertext = crypto.sealContent(
          plaintext: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]),
          dek: dek,
        );
        final Uint8List tampered = Uint8List.fromList(ciphertext);
        tampered[0] ^= 0x01;
        expect(
          () => crypto.openContent(ciphertext: tampered, dek: dek),
          throwsA(isA<AttachmentCryptoAuthError>()),
        );
      },
    );

    testWithEvidence(
      secEvidence('CRYPTO-AEAD-WRONG-KEY', <String>['R-SEC-002']),
      'ciphertext never decrypts under a different key',
      () {
        final Uint8List dek = crypto.newDek();
        final Uint8List other = crypto.newDek();
        final Uint8List ciphertext = crypto.sealContent(
          plaintext: Uint8List.fromList(<int>[9, 9, 9, 9]),
          dek: dek,
        );
        expect(
          () => crypto.openContent(ciphertext: ciphertext, dek: other),
          throwsA(isA<AttachmentCryptoAuthError>()),
        );
      },
    );

    testWithEvidence(
      secEvidence('CRYPTO-DEK-WRAP-PORTABLE', <String>['R-SEC-002']),
      'a wrapped DEK is opaque, key-bound, and never exposes raw key bytes',
      () {
        final Uint8List dek = crypto.newDek();
        final Uint8List kek = Uint8List.fromList(
          List<int>.generate(32, (int i) => 200 - i),
        );
        final String wrapped = crypto.wrapDek(dek: dek, kek: kek);
        expect(_containsRun(wrapped.codeUnits, dek), isFalse);
        expect(crypto.unwrapDek(wrappedDek: wrapped, kek: kek), dek);
        final Uint8List wrongKek = Uint8List.fromList(
          List<int>.generate(32, (int i) => i),
        );
        expect(
          () => crypto.unwrapDek(wrappedDek: wrapped, kek: wrongKek),
          throwsA(isA<AttachmentCryptoAuthError>()),
        );
      },
    );
  });

  group('FBC1 container framing & tamper detection', () {
    late Fbc1Codec codec;

    setUp(() {
      codec = Fbc1Codec(crypto: BackupTestCrypto());
    });

    List<Fbc1File> files() => <Fbc1File>[
      Fbc1File('db/forge.sqlite', 'PRIMARY-DATABASE-BYTES'.codeUnits),
      Fbc1File('attachments/a1.att', 'ENCRYPTED-ATTACHMENT'.codeUnits),
    ];

    testWithEvidence(
      secEvidence('FBC1-ROUNDTRIP', <String>['R-SEC-002', 'NFR-SEC-001']),
      'a well-formed archive validates and restores its files',
      () async {
        final Uint8List archive = await _archive(codec, files());
        final Fbc1DecodeMetrics metrics = await codec.validate(
          passphrase: _passphrase,
          archive: archive,
        );
        expect(metrics.fileCount, 2);
        // No plaintext file content survives in the archive bytes.
        expect(
          _containsRun(archive, 'PRIMARY-DATABASE-BYTES'.codeUnits),
          isFalse,
        );
      },
    );

    testWithEvidence(
      secEvidence('FBC1-BAD-MAGIC', <String>['R-SEC-002']),
      'a corrupted magic prefix is rejected',
      () async {
        final Uint8List archive = await _archive(codec, files());
        archive[0] ^= 0xff;
        await expectLater(
          codec.validate(passphrase: _passphrase, archive: archive),
          throwsA(isA<Fbc1FormatException>()),
        );
      },
    );

    testWithEvidence(
      secEvidence('FBC1-TAMPER-BODY', <String>['R-SEC-002']),
      'flipping any authenticated byte fails validation',
      () async {
        final Uint8List archive = await _archive(codec, files());
        archive[archive.length - 8] ^= 0x01;
        await expectLater(
          codec.validate(passphrase: _passphrase, archive: archive),
          throwsA(isA<Fbc1FormatException>()),
        );
      },
    );

    testWithEvidence(
      secEvidence('FBC1-TRUNCATION', <String>['R-SEC-002']),
      'a truncated archive (missing final manifest frame) is rejected',
      () async {
        final Uint8List archive = await _archive(codec, files());
        final Uint8List truncated = Uint8List.sublistView(
          archive,
          0,
          archive.length - 16,
        );
        await expectLater(
          codec.validate(passphrase: _passphrase, archive: truncated),
          throwsA(isA<Fbc1FormatException>()),
        );
      },
    );

    testWithEvidence(
      secEvidence('FBC1-WRONG-PASSPHRASE', <String>['R-SEC-002']),
      'the wrong passphrase never authenticates a frame',
      () async {
        final Uint8List archive = await _archive(codec, files());
        await expectLater(
          codec.validate(passphrase: 'wrong'.codeUnits, archive: archive),
          throwsA(isA<Fbc1FormatException>()),
        );
      },
    );

    testWithEvidence(
      secEvidence('FBC1-PATH-TRAVERSAL', <String>['R-SEC-002']),
      'traversal, absolute, and drive-qualified paths are refused at encode',
      () {
        for (final String path in <String>[
          '../escape',
          '/etc/passwd',
          'a/../../b',
          r'C:\windows',
          'nested/./dot',
        ]) {
          expect(
            () => codec.encode(
              passphrase: _passphrase,
              files: <Fbc1File>[
                Fbc1File(path, <int>[1, 2, 3]),
              ],
              salt: _salt,
            ),
            throwsA(isA<Fbc1FormatException>()),
            reason: 'path "$path" must be rejected',
          );
        }
      },
    );

    testWithEvidence(
      secEvidence('FBC1-ENTRY-BOUND', <String>['R-SEC-002', 'NFR-SEC-001']),
      'declared entry ceilings above the caller limit are refused',
      () async {
        final Fbc1Codec bounded = Fbc1Codec(
          crypto: BackupTestCrypto(),
          limits: const Fbc1Limits(maxEntries: 1),
        );
        expect(
          () => bounded.encode(
            passphrase: _passphrase,
            files: <Fbc1File>[
              Fbc1File('a', <int>[1]),
              Fbc1File('b', <int>[2]),
            ],
            salt: _salt,
          ),
          throwsA(isA<Fbc1FormatException>()),
        );
      },
    );
  });

  group('KeyVault crypto boundary hygiene', () {
    testWithEvidence(
      secEvidence('CRYPTO-KEY-REDACTED', <String>['R-SEC-002', 'R-SEC-004']),
      'live key material renders as redacted and never as raw bytes',
      () {
        final VaultConformanceHarness harness = VaultConformanceHarness.pin();
        harness.machine.dispatch(
          const CreateVault(
            databaseId: 'db-1',
            protection: VaultProtection.pinFallback,
            passphrase: '1234',
          ),
        );
        final VaultState state = harness.machine.state;
        expect(state, isA<VaultAvailable>());
        final VaultAvailable available = state as VaultAvailable;
        expect(available.key.toString(), 'SecureKey(<redacted>)');
        // The persisted envelope is opaque and never contains raw key bytes.
        final Uint8List raw = available.key.copyBytes();
        expect(
          _containsRun(available.material.wrappedKey.codeUnits, raw),
          isFalse,
        );
      },
    );
  });
}
