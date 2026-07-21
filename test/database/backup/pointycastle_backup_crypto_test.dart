import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto_pkg;
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/backup/infrastructure/fbc1_container.dart';
import 'package:forge/features/backup/infrastructure/pointycastle_backup_crypto.dart';

import '../../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-BACKUP-PCCRYPTO-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('12.1'),
  requirements: <RequirementId>[
    RequirementId('R-BACKUP-001'),
    RequirementId('R-BACKUP-002'),
  ],
);

/// Fast, non-production Argon2id cost parameters. These stay above the FBC1
/// floor (memoryKiB >= 8*1024) while keeping the test suite quick.
const int _memoryKiB = 8 * 1024;
const int _iterations = 1;
const int _parallelism = 1;

Uint8List _key(
  PointyCastleBackupCrypto crypto, {
  required List<int> passphrase,
  required List<int> salt,
  int memoryKiB = _memoryKiB,
  int iterations = _iterations,
  int parallelism = _parallelism,
}) => crypto.deriveKey(
  passphrase: passphrase,
  salt: salt,
  outputLength: crypto.keyLength,
  memoryKiB: memoryKiB,
  iterations: iterations,
  parallelism: parallelism,
);

/// Collects restored file chunks in memory so an end-to-end decode can be
/// compared against the original inputs.
final class _CollectingSink implements Fbc1FileSink {
  final Map<String, BytesBuilder> _files = <String, BytesBuilder>{};

  Map<String, Uint8List> get files => <String, Uint8List>{
    for (final MapEntry<String, BytesBuilder> e in _files.entries)
      e.key: e.value.toBytes(),
  };

  @override
  Future<void> begin(String path, int fileSize) async {
    _files[path] = BytesBuilder(copy: false);
  }

  @override
  Future<void> chunk(String path, Uint8List bytes) async {
    _files[path]!.add(bytes);
  }

  @override
  Future<void> end(String path) async {}
}

void main() {
  final List<int> salt = List<int>.generate(16, (int i) => i);
  final List<int> passphrase = 'correct horse battery staple'.codeUnits;

  group('key derivation', () {
    testWithEvidence(
      _evidence('001'),
      'is deterministic for the same passphrase, salt, and parameters',
      () {
        final PointyCastleBackupCrypto crypto = PointyCastleBackupCrypto();
        final Uint8List a = _key(crypto, passphrase: passphrase, salt: salt);
        final Uint8List b = _key(crypto, passphrase: passphrase, salt: salt);
        expect(a, hasLength(32));
        expect(a, orderedEquals(b));
      },
    );

    testWithEvidence(
      _evidence('002'),
      'a different passphrase, salt, or cost parameter yields a different key',
      () {
        final PointyCastleBackupCrypto crypto = PointyCastleBackupCrypto();
        final Uint8List base = _key(crypto, passphrase: passphrase, salt: salt);

        final Uint8List otherPass = _key(
          crypto,
          passphrase: 'wrong passphrase'.codeUnits,
          salt: salt,
        );
        final Uint8List otherSalt = _key(
          crypto,
          passphrase: passphrase,
          salt: List<int>.generate(16, (int i) => 16 - i),
        );
        final Uint8List otherIters = _key(
          crypto,
          passphrase: passphrase,
          salt: salt,
          iterations: 2,
        );

        expect(base, isNot(orderedEquals(otherPass)));
        expect(base, isNot(orderedEquals(otherSalt)));
        expect(base, isNot(orderedEquals(otherIters)));
      },
    );
  });

  group('per-frame seal/open', () {
    testWithEvidence(
      _evidence('003'),
      'round-trips a frame and expands it by exactly the tag length',
      () {
        final PointyCastleBackupCrypto crypto = PointyCastleBackupCrypto();
        final Uint8List key = _key(crypto, passphrase: passphrase, salt: salt);
        final Uint8List plaintext = Uint8List.fromList(
          List<int>.generate(1000, (int i) => i % 256),
        );
        final Uint8List aad = Uint8List.fromList(<int>[9, 8, 7, 6]);

        final BackupStreamWriter writer = crypto.beginStream(key);
        final Uint8List ciphertext = writer.seal(
          plaintext,
          aad,
          isFinal: false,
        );
        expect(ciphertext.length, plaintext.length + crypto.frameOverhead);

        final BackupStreamReader reader = crypto.openStream(key, writer.header);
        final Uint8List opened = reader.open(ciphertext, aad, isFinal: false);
        expect(opened, orderedEquals(plaintext));
      },
    );

    testWithEvidence(
      _evidence('004'),
      'a tampered ciphertext byte fails authentication and returns no plaintext',
      () {
        final PointyCastleBackupCrypto crypto = PointyCastleBackupCrypto();
        final Uint8List key = _key(crypto, passphrase: passphrase, salt: salt);
        final Uint8List aad = Uint8List.fromList(<int>[1, 2, 3]);
        final BackupStreamWriter writer = crypto.beginStream(key);
        final Uint8List ciphertext = writer.seal(
          Uint8List.fromList(<int>[10, 20, 30, 40, 50]),
          aad,
          isFinal: true,
        );
        final Uint8List tampered = Uint8List.fromList(ciphertext);
        tampered[0] ^= 0x01;

        final BackupStreamReader reader = crypto.openStream(key, writer.header);
        expect(
          () => reader.open(tampered, aad, isFinal: true),
          throwsA(anything),
        );
      },
    );

    testWithEvidence(
      _evidence('005'),
      'a truncated ciphertext fails authentication',
      () {
        final PointyCastleBackupCrypto crypto = PointyCastleBackupCrypto();
        final Uint8List key = _key(crypto, passphrase: passphrase, salt: salt);
        final Uint8List aad = Uint8List.fromList(<int>[4, 5, 6]);
        final BackupStreamWriter writer = crypto.beginStream(key);
        final Uint8List ciphertext = writer.seal(
          Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]),
          aad,
          isFinal: false,
        );
        final Uint8List truncated = Uint8List.sublistView(
          ciphertext,
          0,
          ciphertext.length - 1,
        );
        final BackupStreamReader reader = crypto.openStream(key, writer.header);
        expect(
          () => reader.open(truncated, aad, isFinal: false),
          throwsA(anything),
        );
      },
    );

    testWithEvidence(
      _evidence('006'),
      'a wrong key, wrong AAD, reorder, or flipped finality all fail to open',
      () {
        final PointyCastleBackupCrypto crypto = PointyCastleBackupCrypto();
        final Uint8List key = _key(crypto, passphrase: passphrase, salt: salt);
        final Uint8List aad0 = Uint8List.fromList(<int>[0, 0, 1]);
        final Uint8List aad1 = Uint8List.fromList(<int>[0, 0, 2]);
        final BackupStreamWriter writer = crypto.beginStream(key);
        final Uint8List frame0 = writer.seal(
          Uint8List.fromList(<int>[100, 101, 102]),
          aad0,
          isFinal: false,
        );
        final Uint8List frame1 = writer.seal(
          Uint8List.fromList(<int>[200, 201, 202]),
          aad1,
          isFinal: true,
        );

        // Wrong key.
        final Uint8List wrongKey = _key(
          crypto,
          passphrase: 'nope'.codeUnits,
          salt: salt,
        );
        expect(
          () => crypto
              .openStream(wrongKey, writer.header)
              .open(frame0, aad0, isFinal: false),
          throwsA(anything),
        );

        // Wrong AAD.
        expect(
          () => crypto
              .openStream(key, writer.header)
              .open(frame0, aad1, isFinal: false),
          throwsA(anything),
        );

        // Reorder: opening frame1 first (reader counter 0) must fail.
        expect(
          () => crypto
              .openStream(key, writer.header)
              .open(frame1, aad1, isFinal: true),
          throwsA(anything),
        );

        // Flipped finality on the first frame.
        expect(
          () => crypto
              .openStream(key, writer.header)
              .open(frame0, aad0, isFinal: true),
          throwsA(anything),
        );

        // Sanity: the correct sequence still opens.
        final BackupStreamReader reader = crypto.openStream(key, writer.header);
        expect(
          reader.open(frame0, aad0, isFinal: false),
          orderedEquals(<int>[100, 101, 102]),
        );
        expect(
          reader.open(frame1, aad1, isFinal: true),
          orderedEquals(<int>[200, 201, 202]),
        );
      },
    );
  });

  group('hashing', () {
    testWithEvidence(
      _evidence('007'),
      'hash is SHA-256 and the incremental hash equals the one-shot hash',
      () {
        final PointyCastleBackupCrypto crypto = PointyCastleBackupCrypto();
        final List<int> data = 'the quick brown fox'.codeUnits;
        final Uint8List expected = Uint8List.fromList(
          crypto_pkg.sha256.convert(data).bytes,
        );
        expect(crypto.hash(data), orderedEquals(expected));

        final IncrementalHash inc = crypto.newIncrementalHash();
        inc.add('the quick '.codeUnits);
        inc.add('brown fox'.codeUnits);
        expect(inc.close(), orderedEquals(expected));
      },
    );
  });

  group('end-to-end through Fbc1Codec', () {
    testWithEvidence(
      _evidence('008'),
      'encode -> validate -> restore round-trips with the production adapter',
      () async {
        final Fbc1Codec codec = Fbc1Codec(crypto: PointyCastleBackupCrypto());
        final List<Fbc1File> files = <Fbc1File>[
          Fbc1File('meta.json', 'hello world'.codeUnits),
          Fbc1File(
            'store.bin',
            List<int>.generate(5000, (int i) => (i * 7) % 256),
          ),
        ];
        final Uint8List archive = codec.encode(
          passphrase: passphrase,
          files: files,
          salt: salt,
          kdf: const Fbc1KdfParameters(
            memoryKiB: _memoryKiB,
            iterations: _iterations,
          ),
          chunkSize: 1024,
        );

        final Fbc1DecodeMetrics metrics = await codec.validate(
          passphrase: passphrase,
          archive: archive,
        );
        expect(metrics.fileCount, 2);

        final _CollectingSink sink = _CollectingSink();
        await codec.restore(
          passphrase: passphrase,
          archive: archive,
          sink: sink,
        );
        expect(sink.files['meta.json'], orderedEquals('hello world'.codeUnits));
        expect(
          sink.files['store.bin'],
          orderedEquals(List<int>.generate(5000, (int i) => (i * 7) % 256)),
        );
      },
    );

    testWithEvidence(
      _evidence('009'),
      'a wrong passphrase cannot open the archive (fails validation)',
      () async {
        final Fbc1Codec codec = Fbc1Codec(crypto: PointyCastleBackupCrypto());
        final Uint8List archive = codec.encode(
          passphrase: passphrase,
          files: <Fbc1File>[Fbc1File('a.txt', 'secret'.codeUnits)],
          salt: salt,
          kdf: const Fbc1KdfParameters(
            memoryKiB: _memoryKiB,
            iterations: _iterations,
          ),
        );
        expect(
          () => codec.validate(
            passphrase: 'the wrong passphrase'.codeUnits,
            archive: archive,
          ),
          throwsA(
            isA<Fbc1FormatException>().having(
              (Fbc1FormatException e) => e.code,
              'code',
              'authentication_failed',
            ),
          ),
        );
      },
    );

    testWithEvidence(
      _evidence('010'),
      'a tampered archive body fails bounded authenticated validation',
      () async {
        final Fbc1Codec codec = Fbc1Codec(crypto: PointyCastleBackupCrypto());
        final Uint8List archive = codec.encode(
          passphrase: passphrase,
          files: <Fbc1File>[Fbc1File('a.txt', 'secret data here'.codeUnits)],
          salt: salt,
          kdf: const Fbc1KdfParameters(
            memoryKiB: _memoryKiB,
            iterations: _iterations,
          ),
        );
        // Flip a byte near the end (inside the first sealed frame's body/tag).
        final Uint8List tampered = Uint8List.fromList(archive);
        tampered[tampered.length - 20] ^= 0x01;
        expect(
          () => codec.validate(passphrase: passphrase, archive: tampered),
          throwsA(isA<Fbc1FormatException>()),
        );
      },
    );
  });
}
