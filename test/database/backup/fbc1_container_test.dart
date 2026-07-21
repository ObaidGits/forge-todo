import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/backup/infrastructure/fbc1_container.dart';

import '../../helpers/backup_test_crypto.dart';
import '../../helpers/helpers.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-BACKUP-FBC1-CONTAINER-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.6'),
  requirements: <RequirementId>[
    RequirementId('R-BACKUP-001'),
    RequirementId('R-BACKUP-002'),
  ],
);

/// Captures decoded files in memory so a round trip can be asserted.
final class _CaptureSink implements Fbc1FileSink {
  final Map<String, BytesBuilder> _building = <String, BytesBuilder>{};
  final Map<String, Uint8List> files = <String, Uint8List>{};

  @override
  Future<void> begin(String path, int fileSize) async {
    _building[path] = BytesBuilder(copy: false);
  }

  @override
  Future<void> chunk(String path, Uint8List bytes) async {
    _building[path]!.add(bytes);
  }

  @override
  Future<void> end(String path) async {
    files[path] = _building.remove(path)!.takeBytes();
  }
}

List<int> _passphrase(String value) => value.codeUnits;

void main() {
  late Fbc1Codec codec;
  final List<int> salt = List<int>.generate(16, (int i) => i);

  setUp(() {
    codec = Fbc1Codec(crypto: BackupTestCrypto());
  });

  Uint8List encodeSample({
    int chunkSize = 1024 * 1024,
    List<Fbc1File>? files,
  }) => codec.encode(
    passphrase: _passphrase('correct horse'),
    salt: salt,
    chunkSize: chunkSize,
    files:
        files ??
        <Fbc1File>[
          Fbc1File('backup_meta.json', 'meta'.codeUnits),
          Fbc1File(
            'store.sqlite',
            List<int>.generate(5000, (int i) => i % 256),
          ),
        ],
  );

  testWithEvidence(
    _evidence('001'),
    'a multi-file, multi-chunk archive round trips byte-for-byte',
    () async {
      final Uint8List archive = encodeSample(chunkSize: 512);
      final _CaptureSink sink = _CaptureSink();
      final Fbc1DecodeMetrics metrics = await codec.restore(
        passphrase: _passphrase('correct horse'),
        archive: archive,
        sink: sink,
      );
      expect(metrics.fileCount, 2);
      expect(sink.files['backup_meta.json'], 'meta'.codeUnits);
      expect(
        sink.files['store.sqlite'],
        List<int>.generate(5000, (int i) => i % 256),
      );
    },
  );

  testWithEvidence(
    _evidence('002'),
    'an empty file and a UTF-8 path round trip',
    () async {
      final Uint8List archive = encodeSample(
        chunkSize: 64,
        files: <Fbc1File>[
          Fbc1File('empty.bin', const <int>[]),
          Fbc1File('nested/naïve.txt', 'héllo'.codeUnits),
        ],
      );
      final _CaptureSink sink = _CaptureSink();
      await codec.restore(
        passphrase: _passphrase('correct horse'),
        archive: archive,
        sink: sink,
      );
      expect(sink.files['empty.bin'], isEmpty);
      expect(sink.files['nested/naïve.txt'], 'héllo'.codeUnits);
    },
  );

  testWithEvidence(
    _evidence('003'),
    'validation is memory-bounded: peak frame stays near the chunk size for a '
    'large file',
    () async {
      final Uint8List archive = codec.encode(
        passphrase: _passphrase('pw'),
        salt: salt,
        chunkSize: 1024,
        files: <Fbc1File>[
          Fbc1File('store.sqlite', List<int>.filled(200 * 1024, 7)),
        ],
      );
      final Fbc1DecodeMetrics metrics = await codec.validate(
        passphrase: _passphrase('pw'),
        archive: archive,
      );
      expect(metrics.plaintextBytes, 200 * 1024);
      // Peak buffered frame is one chunk plus small CBOR overhead, far below
      // the whole-file size.
      expect(metrics.peakFrameBytes, lessThan(4 * 1024));
    },
  );

  testWithEvidence(
    _evidence('004'),
    'a wrong passphrase fails authentication',
    () async {
      final Uint8List archive = encodeSample();
      await expectLater(
        codec.validate(passphrase: _passphrase('wrong'), archive: archive),
        throwsA(isA<Fbc1FormatException>()),
      );
    },
  );

  testWithEvidence(
    _evidence('005'),
    'tampering with any ciphertext byte fails authentication',
    () async {
      final Uint8List archive = encodeSample();
      archive[archive.length - 20] ^= 0x01;
      await expectLater(
        codec.validate(
          passphrase: _passphrase('correct horse'),
          archive: archive,
        ),
        throwsA(isA<Fbc1FormatException>()),
      );
    },
  );

  testWithEvidence(
    _evidence('006'),
    'truncating the archive is rejected',
    () async {
      final Uint8List archive = encodeSample();
      final Uint8List truncated = Uint8List.sublistView(
        archive,
        0,
        archive.length - 10,
      );
      await expectLater(
        codec.validate(
          passphrase: _passphrase('correct horse'),
          archive: truncated,
        ),
        throwsA(isA<Fbc1FormatException>()),
      );
    },
  );

  testWithEvidence(
    _evidence('007'),
    'appending a trailing byte after the final frame is rejected',
    () async {
      final Uint8List archive = encodeSample();
      final Uint8List extended = Uint8List(archive.length + 1)
        ..setRange(0, archive.length, archive);
      await expectLater(
        codec.validate(
          passphrase: _passphrase('correct horse'),
          archive: extended,
        ),
        throwsA(
          isA<Fbc1FormatException>().having(
            (Fbc1FormatException e) => e.code,
            'code',
            'trailing_frame',
          ),
        ),
      );
    },
  );

  testWithEvidence(
    _evidence('008'),
    'corrupting the magic bytes is rejected as malformed',
    () async {
      final Uint8List archive = encodeSample();
      archive[0] ^= 0xff;
      await expectLater(
        codec.validate(
          passphrase: _passphrase('correct horse'),
          archive: archive,
        ),
        throwsA(
          isA<Fbc1FormatException>().having(
            (Fbc1FormatException e) => e.code,
            'code',
            'bad_magic',
          ),
        ),
      );
    },
  );

  testWithEvidence(
    _evidence('009'),
    'reordering frames is rejected by the monotonic frame index',
    () async {
      // Two files, small chunk => at least two data frames. Swapping the two
      // leading frame regions breaks the monotonic index contract.
      final Uint8List archive = codec.encode(
        passphrase: _passphrase('pw'),
        salt: salt,
        chunkSize: 8,
        files: <Fbc1File>[
          Fbc1File('a', List<int>.filled(8, 1)),
          Fbc1File('b', List<int>.filled(8, 2)),
        ],
      );
      // Locate the two data frames right after the header and swap them. Each
      // frame is [type(1)][index(8)][plen(4)][clen(4)][ciphertext]. We parse
      // the header length to find the first frame offset.
      final ByteData view = ByteData.sublistView(archive);
      final int headerLength = view.getUint32(4, Endian.big);
      final int firstFrame = 8 + headerLength;
      int frameSize(int at) {
        final int plen = view.getUint32(at + 9, Endian.big);
        final int clen = view.getUint32(at + 13, Endian.big);
        // ignore: unused_local_variable
        final int _ = plen;
        return 17 + clen;
      }

      final int size0 = frameSize(firstFrame);
      final int secondFrame = firstFrame + size0;
      final int size1 = frameSize(secondFrame);
      final Uint8List swapped = Uint8List.fromList(archive);
      swapped.setRange(
        firstFrame,
        firstFrame + size1,
        archive.sublist(secondFrame, secondFrame + size1),
      );
      swapped.setRange(
        firstFrame + size1,
        firstFrame + size1 + size0,
        archive.sublist(firstFrame, firstFrame + size0),
      );
      await expectLater(
        codec.validate(passphrase: _passphrase('pw'), archive: swapped),
        throwsA(isA<Fbc1FormatException>()),
      );
    },
  );

  testWithEvidence(
    _evidence('010'),
    'encoding rejects an unsafe traversal path',
    () async {
      expect(
        () => codec.encode(
          passphrase: _passphrase('pw'),
          salt: salt,
          files: <Fbc1File>[Fbc1File('../evil', 'x'.codeUnits)],
        ),
        throwsA(isA<Fbc1FormatException>()),
      );
    },
  );

  testWithEvidence(
    _evidence('011'),
    'encoding rejects a wrong-length salt',
    () async {
      expect(
        () => codec.encode(
          passphrase: _passphrase('pw'),
          salt: const <int>[1, 2, 3],
          files: <Fbc1File>[Fbc1File('a', 'x'.codeUnits)],
        ),
        throwsA(isA<ArgumentError>()),
      );
    },
  );
}
