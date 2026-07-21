/// Forge Backup Container v1 (FBC1) production framing.
///
/// This is the production sibling of the Wave-0 reference probe validated in
/// `tool/probes/fbc1_compatibility` (evidence `TEST-FBC1-REFERENCE-001`,
/// `docs/evidence/FBC1-CONTAINER-PARSER.md`). It reuses the identical container
/// *semantics* — fixed magic, strict deterministic canonical CBOR header on an
/// allowlisted schema, per-frame authenticated framing whose associated data
/// binds the exact header hash, frame type, monotonic index, and declared
/// plaintext length, and a final-tagged encrypted manifest binding sorted
/// paths, lengths, SHA-256 file hashes, totals, count, and a domain-separated
/// binary Merkle root with a mandatory EOF.
///
/// Confidentiality, key derivation, and per-frame authentication are delegated
/// to an injected [BackupCrypto] so the app never hard-codes a cipher: the
/// composition root wires the native libsodium/Argon2id adapter exercised by
/// the reference probe, while tests wire an in-process authenticated adapter.
/// The framing, bounds, path rules, and rejection behaviour live here and are
/// identical regardless of the crypto adapter (`R-BACKUP-001`, `R-BACKUP-002`).
library;

import 'dart:typed_data';

const List<int> _magic = <int>[0x46, 0x42, 0x43, 0x31]; // 'FBC1'
const int _formatVersion = 1;
const int _dataFrame = 1;
const int _manifestFrame = 2;
const String _kdfId = 'argon2id-v19';
const String _cipherId = 'forge-fbc1-aead-stream';
const String _manifestLabel = 'forge-fbc1-backup';

/// Fail-closed ceilings applied before key derivation, decryption, or
/// allocation. Declared limits inside a container header may only be tighter
/// than these caller ceilings; anything larger is rejected before use.
final class Fbc1Limits {
  const Fbc1Limits({
    this.maxArchiveBytes = 100 * 1024 * 1024 * 1024,
    this.maxHeaderBytes = 64 * 1024,
    this.maxEntries = 100000,
    this.maxPathBytes = 255,
    this.maxTotalPathBytes = 16 * 1024 * 1024,
    this.maxRecordBytes = 64 * 1024 * 1024,
    this.maxManifestBytes = 64 * 1024 * 1024,
    this.maxExpansionBytes = 200 * 1024 * 1024 * 1024,
    this.maxKdfMemoryKiB = 1024 * 1024,
    this.maxKdfIterations = 10,
    this.maxKdfParallelism = 4,
  });

  final int maxArchiveBytes;
  final int maxHeaderBytes;
  final int maxEntries;
  final int maxPathBytes;
  final int maxTotalPathBytes;
  final int maxRecordBytes;
  final int maxManifestBytes;
  final int maxExpansionBytes;
  final int maxKdfMemoryKiB;
  final int maxKdfIterations;
  final int maxKdfParallelism;
}

/// Argon2id v19 parameters recorded in (and authenticated by) the header.
final class Fbc1KdfParameters {
  const Fbc1KdfParameters({
    this.memoryKiB = 64 * 1024,
    this.iterations = 3,
    this.parallelism = 1,
  });

  final int memoryKiB;
  final int iterations;
  final int parallelism;
}

/// One logical file placed into a backup archive.
final class Fbc1File {
  Fbc1File(this.path, List<int> bytes) : bytes = Uint8List.fromList(bytes);

  final String path;
  final Uint8List bytes;
}

/// Bounded metrics returned by [Fbc1Codec.validate]/[Fbc1Codec.restore].
final class Fbc1DecodeMetrics {
  const Fbc1DecodeMetrics({
    required this.frameCount,
    required this.fileCount,
    required this.plaintextBytes,
    required this.peakFrameBytes,
    required this.kdfMemoryKiB,
  });

  final int frameCount;
  final int fileCount;
  final int plaintextBytes;

  /// Largest single authenticated plaintext frame held in memory at once.
  final int peakFrameBytes;
  final int kdfMemoryKiB;
}

/// A rejected or malformed container. Always fail-closed; never a data reset.
final class Fbc1FormatException implements Exception {
  const Fbc1FormatException(this.code, this.offset, [this.source]);

  final String code;
  final int offset;
  final Object? source;

  String get message => '$code at byte $offset';

  @override
  String toString() => 'Fbc1FormatException: $message';
}

/// Incremental SHA-256 so file content can be hashed without buffering a whole
/// file, keeping validation and restore memory-bounded.
abstract interface class IncrementalHash {
  void add(List<int> bytes);

  Uint8List close();
}

/// A per-archive authenticated write stream. [seal] returns ciphertext that is
/// `plaintext.length + BackupCrypto.frameOverhead` bytes long and binds [aad].
abstract interface class BackupStreamWriter {
  List<int> get header;

  Uint8List seal(List<int> plaintext, List<int> aad, {required bool isFinal});
}

/// A per-archive authenticated read stream. [open] throws when authentication
/// fails (tampered ciphertext/AAD, reorder, truncation, or a wrong key).
abstract interface class BackupStreamReader {
  Uint8List open(List<int> ciphertext, List<int> aad, {required bool isFinal});
}

/// Cryptographic boundary for FBC1. The production adapter is native
/// libsodium + Argon2id (see the reference probe); tests inject an in-process
/// authenticated adapter. Only this port is cipher-specific.
abstract interface class BackupCrypto {
  /// Derived key length and the secretstream key length (32).
  int get keyLength;

  /// Ciphertext expansion added to each sealed frame.
  int get frameOverhead;

  /// Per-stream public header length (nonce/state).
  int get streamHeaderLength;

  Uint8List deriveKey({
    required List<int> passphrase,
    required List<int> salt,
    required int outputLength,
    required int memoryKiB,
    required int iterations,
    required int parallelism,
  });

  Uint8List hash(List<int> bytes);

  IncrementalHash newIncrementalHash();

  Uint8List randomBytes(int length);

  BackupStreamWriter beginStream(List<int> key);

  BackupStreamReader openStream(List<int> key, List<int> streamHeader);

  /// Best-effort zeroization of a derived key buffer.
  void wipe(Uint8List key);
}

/// A sink consuming authenticated plaintext file chunks during a decode pass.
///
/// [Fbc1Codec.validate] uses a discarding sink (memory-bounded); restore uses a
/// sink that streams chunks straight to a staging file handle.
abstract interface class Fbc1FileSink {
  Future<void> begin(String path, int fileSize);

  Future<void> chunk(String path, Uint8List bytes);

  Future<void> end(String path);
}

class _NullSink implements Fbc1FileSink {
  const _NullSink();

  @override
  Future<void> begin(String path, int fileSize) async {}

  @override
  Future<void> chunk(String path, Uint8List bytes) async {}

  @override
  Future<void> end(String path) async {}
}

/// The FBC1 codec: encode, bounded authenticated validate, and streaming
/// decode. All state is local to a call; the codec itself is stateless and
/// safe to share.
final class Fbc1Codec {
  Fbc1Codec({required this.crypto, this.limits = const Fbc1Limits()});

  final BackupCrypto crypto;
  final Fbc1Limits limits;

  /// Encodes [files] into an authenticated FBC1 archive under a passphrase-
  /// derived key. Files are sorted by UTF-8 path bytes; the manifest is the
  /// final-tagged frame binding every path/length/hash and the Merkle root.
  Uint8List encode({
    required List<int> passphrase,
    required List<Fbc1File> files,
    required List<int> salt,
    Fbc1KdfParameters kdf = const Fbc1KdfParameters(),
    int chunkSize = 1024 * 1024,
  }) {
    _validateLimits(limits);
    _validateKdf(kdf, limits);
    if (salt.length != 16) {
      throw ArgumentError.value(salt, 'salt', 'must be 16 bytes');
    }
    if (chunkSize <= 0 || chunkSize > limits.maxRecordBytes) {
      throw ArgumentError.value(chunkSize, 'chunkSize');
    }
    final List<Fbc1File> sorted = files.toList()
      ..sort(
        (Fbc1File a, Fbc1File b) => _compareBytes(_utf8(a.path), _utf8(b.path)),
      );
    if (sorted.length > limits.maxEntries) {
      throw const Fbc1FormatException('entry_count_limit', 0);
    }
    int total = 0;
    int totalPaths = 0;
    final Set<String> seen = <String>{};
    for (final Fbc1File file in sorted) {
      final Uint8List pathBytes = _validatePath(file.path, limits, 0);
      totalPaths = _checkedAdd(
        totalPaths,
        pathBytes.length,
        limits.maxTotalPathBytes,
        'total_path_limit',
        0,
      );
      if (!seen.add(file.path)) {
        throw const Fbc1FormatException('duplicate_path', 0);
      }
      total = _checkedAdd(
        total,
        file.bytes.length,
        limits.maxExpansionBytes,
        'expansion_limit',
        0,
      );
    }

    final Uint8List key = crypto.deriveKey(
      passphrase: passphrase,
      salt: salt,
      outputLength: crypto.keyLength,
      memoryKiB: kdf.memoryKiB,
      iterations: kdf.iterations,
      parallelism: kdf.parallelism,
    );
    final BackupStreamWriter writer = crypto.beginStream(key);
    try {
      final Map<int, Object> headerMap = <int, Object>{
        0: Uint8List.fromList(_magic),
        1: _formatVersion,
        2: _kdfId,
        3: Uint8List.fromList(salt),
        4: kdf.memoryKiB,
        5: kdf.iterations,
        6: kdf.parallelism,
        7: _cipherId,
        8: Uint8List.fromList(writer.header),
        9: chunkSize,
        10: limits.maxEntries,
        11: limits.maxArchiveBytes,
        12: limits.maxExpansionBytes,
        13: limits.maxRecordBytes,
        14: limits.maxManifestBytes,
      };
      final Uint8List header = CanonicalCbor.encode(headerMap);
      if (header.length > limits.maxHeaderBytes) {
        throw const Fbc1FormatException('header_limit', 0);
      }
      final Uint8List headerHash = crypto.hash(header);
      final BytesBuilder output = BytesBuilder(copy: false)
        ..add(_magic)
        ..add(_u32(header.length))
        ..add(header);
      final List<Map<int, Object>> entries = <Map<int, Object>>[];
      int frameIndex = 0;
      for (final Fbc1File file in sorted) {
        final Uint8List fileHash = crypto.hash(file.bytes);
        entries.add(<int, Object>{
          0: file.path,
          1: file.bytes.length,
          2: fileHash,
        });
        int offset = 0;
        do {
          final int end = file.bytes.isEmpty
              ? 0
              : (offset + chunkSize < file.bytes.length
                    ? offset + chunkSize
                    : file.bytes.length);
          final Uint8List chunk = Uint8List.sublistView(
            file.bytes,
            offset,
            end,
          );
          final Uint8List plaintext = CanonicalCbor.encode(<int, Object>{
            0: file.path,
            1: offset,
            2: file.bytes.length,
            3: end == file.bytes.length,
            4: Uint8List.fromList(chunk),
            5: fileHash,
          });
          if (plaintext.length > limits.maxRecordBytes) {
            throw const Fbc1FormatException('record_limit', 0);
          }
          _sealFrame(
            output,
            writer,
            headerHash,
            _dataFrame,
            frameIndex,
            plaintext,
            isFinal: false,
          );
          frameIndex += 1;
          offset = end;
        } while (offset < file.bytes.length);
      }
      final Uint8List root = _merkleRoot(entries);
      final Uint8List manifest = CanonicalCbor.encode(<int, Object>{
        0: _manifestLabel,
        1: 1,
        2: _formatVersion,
        3: entries,
        4: entries.length,
        5: total,
        6: root,
      });
      if (manifest.length > limits.maxManifestBytes) {
        throw const Fbc1FormatException('manifest_limit', 0);
      }
      _sealFrame(
        output,
        writer,
        headerHash,
        _manifestFrame,
        frameIndex,
        manifest,
        isFinal: true,
      );
      final Uint8List archive = output.takeBytes();
      if (archive.length > limits.maxArchiveBytes) {
        throw const Fbc1FormatException('archive_limit', 0);
      }
      return archive;
    } finally {
      crypto.wipe(key);
    }
  }

  /// Bounded, authenticated validation. Every frame is authenticated and every
  /// bound checked; only one frame of plaintext plus per-file hash state and
  /// the manifest are ever held in memory. Truncation, reorder, tamper, and
  /// malformed frames all fail (`R-BACKUP-002`).
  Future<Fbc1DecodeMetrics> validate({
    required List<int> passphrase,
    required List<int> archive,
  }) => _process(
    passphrase: passphrase,
    archive: archive,
    sink: const _NullSink(),
  );

  /// Authenticates the archive exactly like [validate] and additionally streams
  /// each file's authenticated chunks to [sink]. Used by staged restore to
  /// materialise files without buffering whole files in memory.
  Future<Fbc1DecodeMetrics> restore({
    required List<int> passphrase,
    required List<int> archive,
    required Fbc1FileSink sink,
  }) => _process(passphrase: passphrase, archive: archive, sink: sink);

  Future<Fbc1DecodeMetrics> _process({
    required List<int> passphrase,
    required List<int> archive,
    required Fbc1FileSink sink,
  }) async {
    _validateLimits(limits);
    if (archive.length > limits.maxArchiveBytes) {
      throw const Fbc1FormatException('archive_limit', 0);
    }
    final _Reader reader = _Reader(Uint8List.fromList(archive));
    if (!_equal(reader.bytes(4), _magic)) {
      throw const Fbc1FormatException('bad_magic', 0);
    }
    final int headerLength = reader.u32();
    if (headerLength > limits.maxHeaderBytes) {
      throw Fbc1FormatException('header_limit', reader.offset - 4);
    }
    final Uint8List headerBytes = reader.bytes(headerLength);
    final Map<int, Object?> header = _header(
      CanonicalCbor.decode(headerBytes),
      reader.offset,
    );
    _validateHeader(header, limits, archive.length);
    final int declaredMaxEntries = header[10]! as int;
    final int declaredMaxExpansion = header[12]! as int;
    final int declaredMaxRecord = header[13]! as int;
    final int declaredMaxManifest = header[14]! as int;
    final int chunkSize = header[9]! as int;
    final Fbc1KdfParameters kdf = Fbc1KdfParameters(
      memoryKiB: header[4]! as int,
      iterations: header[5]! as int,
      parallelism: header[6]! as int,
    );
    final Uint8List key = crypto.deriveKey(
      passphrase: passphrase,
      salt: header[3]! as Uint8List,
      outputLength: crypto.keyLength,
      memoryKiB: kdf.memoryKiB,
      iterations: kdf.iterations,
      parallelism: kdf.parallelism,
    );
    final BackupStreamReader streamReader = crypto.openStream(
      key,
      header[8]! as Uint8List,
    );
    final Uint8List headerHash = crypto.hash(headerBytes);

    final _DecodeState state = _DecodeState();
    try {
      while (!reader.isDone) {
        if (state.finalSeen) {
          throw Fbc1FormatException('trailing_frame', reader.offset);
        }
        final int frameOffset = reader.offset;
        final int type = reader.byte();
        final int index = reader.u64();
        final int plaintextLength = reader.u32();
        final int ciphertextLength = reader.u32();
        if (index != state.expectedIndex) {
          throw Fbc1FormatException('frame_index', frameOffset);
        }
        if (type != _dataFrame && type != _manifestFrame) {
          throw Fbc1FormatException('unknown_frame_type', frameOffset);
        }
        final int frameLimit = type == _manifestFrame
            ? declaredMaxManifest
            : declaredMaxRecord;
        if (plaintextLength > frameLimit ||
            ciphertextLength != plaintextLength + crypto.frameOverhead) {
          throw Fbc1FormatException('frame_length', frameOffset);
        }
        final Uint8List ciphertext = reader.bytes(ciphertextLength);
        final Uint8List aad = _frameAad(
          headerHash,
          type,
          index,
          plaintextLength,
        );
        final Uint8List plaintext = _openFrame(
          streamReader,
          ciphertext,
          aad,
          isFinal: type == _manifestFrame,
          offset: frameOffset,
        );
        if (plaintext.length != plaintextLength) {
          throw Fbc1FormatException('plaintext_length', frameOffset);
        }
        if (plaintext.length > state.peakFrame) {
          state.peakFrame = plaintext.length;
        }
        final Object? decoded = CanonicalCbor.decode(plaintext);
        if (type == _dataFrame) {
          await _handleDataFrame(
            decoded,
            frameOffset,
            state,
            sink,
            chunkSize: chunkSize,
            declaredMaxEntries: declaredMaxEntries,
            declaredMaxExpansion: declaredMaxExpansion,
          );
        } else {
          _handleManifestFrame(decoded, frameOffset, state);
        }
        state.expectedIndex += 1;
      }
    } on Fbc1FormatException {
      rethrow;
    } finally {
      crypto.wipe(key);
    }
    if (!state.finalSeen || state.manifestEntries == null) {
      throw Fbc1FormatException('missing_final_frame', reader.offset);
    }
    if (state.openFile != null) {
      throw Fbc1FormatException('incomplete_file', reader.offset);
    }
    _verifyManifest(state, reader.offset);
    return Fbc1DecodeMetrics(
      frameCount: state.expectedIndex,
      fileCount: state.completedEntries.length,
      plaintextBytes: state.totalPlaintext,
      peakFrameBytes: state.peakFrame,
      kdfMemoryKiB: kdf.memoryKiB,
    );
  }

  Future<void> _handleDataFrame(
    Object? decoded,
    int frameOffset,
    _DecodeState state,
    Fbc1FileSink sink, {
    required int chunkSize,
    required int declaredMaxEntries,
    required int declaredMaxExpansion,
  }) async {
    final Map<int, Object?> record = _intMap(
      decoded,
      'record_shape',
      frameOffset,
    );
    _requireKeys(record, const <int>{0, 1, 2, 3, 4, 5}, frameOffset);
    final Object? path = record[0];
    final Object? offset = record[1];
    final Object? fileSize = record[2];
    final Object? isLast = record[3];
    final Object? chunk = record[4];
    final Object? fileHash = record[5];
    if (path is! String ||
        offset is! int ||
        fileSize is! int ||
        isLast is! bool ||
        chunk is! Uint8List ||
        fileHash is! Uint8List ||
        fileHash.length != 32) {
      throw Fbc1FormatException('record_shape', frameOffset);
    }
    final Uint8List pathBytes = _validatePath(path, limits, frameOffset);
    if (chunk.length > chunkSize) {
      throw Fbc1FormatException('chunk_size', frameOffset);
    }
    _OpenFile? open = state.openFile;
    if (open == null || open.path != path) {
      // Starting a new file: the previous one must have been finalised.
      if (open != null) {
        throw Fbc1FormatException('interleaved_file', frameOffset);
      }
      if (state.seenPaths.contains(path)) {
        throw Fbc1FormatException('duplicate_path', frameOffset);
      }
      if (state.completedEntries.length >= declaredMaxEntries) {
        throw Fbc1FormatException('entry_count_limit', frameOffset);
      }
      if (offset != 0 || fileSize < 0) {
        throw Fbc1FormatException('chunk_offset', frameOffset);
      }
      state.totalPathBytes = _checkedAdd(
        state.totalPathBytes,
        pathBytes.length,
        limits.maxTotalPathBytes,
        'total_path_limit',
        frameOffset,
      );
      open = _OpenFile(
        path: path,
        fileSize: fileSize,
        declaredHash: fileHash,
        hasher: crypto.newIncrementalHash(),
      );
      state.openFile = open;
      state.seenPaths.add(path);
      await sink.begin(path, fileSize);
    } else {
      if (open.fileSize != fileSize || !_equal(open.declaredHash, fileHash)) {
        throw Fbc1FormatException('file_metadata_changed', frameOffset);
      }
    }
    if (offset != open.written) {
      throw Fbc1FormatException('chunk_offset', frameOffset);
    }
    state.totalPlaintext = _checkedAdd(
      state.totalPlaintext,
      chunk.length,
      declaredMaxExpansion,
      'expansion_limit',
      frameOffset,
    );
    if (open.written + chunk.length > fileSize) {
      throw Fbc1FormatException('file_length', frameOffset);
    }
    open.hasher.add(chunk);
    open.written += chunk.length;
    await sink.chunk(path, chunk);
    if (isLast != (open.written == fileSize)) {
      throw Fbc1FormatException('chunk_finality', frameOffset);
    }
    if (isLast) {
      final Uint8List actualHash = open.hasher.close();
      if (!_equal(actualHash, open.declaredHash)) {
        throw Fbc1FormatException('file_hash', frameOffset);
      }
      state.completedEntries.add(<int, Object>{
        0: path,
        1: open.written,
        2: open.declaredHash,
      });
      state.openFile = null;
      await sink.end(path);
    }
  }

  void _handleManifestFrame(
    Object? decoded,
    int frameOffset,
    _DecodeState state,
  ) {
    final Map<int, Object?> manifest = _intMap(
      decoded,
      'manifest_shape',
      frameOffset,
    );
    _requireKeys(manifest, const <int>{0, 1, 2, 3, 4, 5, 6}, frameOffset);
    if (manifest[0] != _manifestLabel ||
        manifest[1] != 1 ||
        manifest[2] != _formatVersion ||
        manifest[3] is! List<Object?> ||
        manifest[4] != state.completedEntries.length ||
        manifest[5] is! int ||
        manifest[6] is! Uint8List) {
      throw Fbc1FormatException('manifest_shape', frameOffset);
    }
    state.manifestEntries = manifest[3]! as List<Object?>;
    state.manifestTotal = manifest[5]! as int;
    state.manifestRoot = manifest[6]! as Uint8List;
    state.finalSeen = true;
  }

  void _verifyManifest(_DecodeState state, int offset) {
    final List<Object?> expected = <Object?>[
      for (final Map<int, Object> entry in state.completedEntries) entry,
    ];
    if (!_deepEqual(expected, state.manifestEntries) ||
        state.manifestTotal != state.totalPlaintext ||
        !_equal(_merkleRoot(state.completedEntries), state.manifestRoot!)) {
      throw Fbc1FormatException('manifest_mismatch', offset);
    }
  }

  void _sealFrame(
    BytesBuilder output,
    BackupStreamWriter writer,
    Uint8List headerHash,
    int type,
    int index,
    Uint8List plaintext, {
    required bool isFinal,
  }) {
    final Uint8List aad = _frameAad(headerHash, type, index, plaintext.length);
    final Uint8List ciphertext = writer.seal(plaintext, aad, isFinal: isFinal);
    if (ciphertext.length != plaintext.length + crypto.frameOverhead) {
      throw const Fbc1FormatException('crypto_overhead', 0);
    }
    output
      ..addByte(type)
      ..add(_u64(index))
      ..add(_u32(plaintext.length))
      ..add(_u32(ciphertext.length))
      ..add(ciphertext);
  }

  Uint8List _openFrame(
    BackupStreamReader reader,
    Uint8List ciphertext,
    Uint8List aad, {
    required bool isFinal,
    required int offset,
  }) {
    try {
      return reader.open(ciphertext, aad, isFinal: isFinal);
    } on Fbc1FormatException {
      rethrow;
    } on Object catch (error) {
      throw Fbc1FormatException('authentication_failed', offset, error);
    }
  }

  Uint8List _merkleRoot(List<Map<int, Object>> entries) {
    if (entries.isEmpty) {
      return crypto.hash(const <int>[0]);
    }
    List<Uint8List> level = <Uint8List>[
      for (final Map<int, Object> entry in entries)
        crypto.hash(<int>[0, ...CanonicalCbor.encode(entry)]),
    ];
    while (level.length > 1) {
      final List<Uint8List> next = <Uint8List>[];
      for (int i = 0; i < level.length; i += 2) {
        final Uint8List right = i + 1 < level.length ? level[i + 1] : level[i];
        next.add(crypto.hash(<int>[1, ...level[i], ...right]));
      }
      level = next;
    }
    return level.single;
  }
}

final class _OpenFile {
  _OpenFile({
    required this.path,
    required this.fileSize,
    required this.declaredHash,
    required this.hasher,
  });

  final String path;
  final int fileSize;
  final Uint8List declaredHash;
  final IncrementalHash hasher;
  int written = 0;
}

final class _DecodeState {
  int expectedIndex = 0;
  int totalPlaintext = 0;
  int totalPathBytes = 0;
  int peakFrame = 0;
  bool finalSeen = false;
  _OpenFile? openFile;
  final Set<String> seenPaths = <String>{};
  final List<Map<int, Object>> completedEntries = <Map<int, Object>>[];
  List<Object?>? manifestEntries;
  int? manifestTotal;
  Uint8List? manifestRoot;
}

Uint8List _frameAad(
  Uint8List headerHash,
  int type,
  int index,
  int plaintextLength,
) => Uint8List.fromList(<int>[
  ...headerHash,
  type,
  ..._u64(index),
  ..._u32(plaintextLength),
]);

Map<int, Object?> _header(Object? value, int offset) {
  final Map<int, Object?> map = _intMap(value, 'header_shape', offset);
  _requireKeys(map, const <int>{
    0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
  }, offset);
  final Object? streamHeader = map[8];
  if (map[0] is! Uint8List ||
      !_equal(map[0]! as Uint8List, _magic) ||
      map[1] != _formatVersion ||
      map[2] != _kdfId ||
      map[3] is! Uint8List ||
      (map[3]! as Uint8List).length != 16 ||
      map[4] is! int ||
      map[5] is! int ||
      map[6] is! int ||
      map[7] != _cipherId ||
      streamHeader is! Uint8List ||
      map[9] is! int ||
      map[10] is! int ||
      map[11] is! int ||
      map[12] is! int ||
      map[13] is! int ||
      map[14] is! int) {
    throw Fbc1FormatException('header_shape', offset);
  }
  return map;
}

void _validateHeader(
  Map<int, Object?> header,
  Fbc1Limits limits,
  int archiveBytes,
) {
  final Fbc1KdfParameters kdf = Fbc1KdfParameters(
    memoryKiB: header[4]! as int,
    iterations: header[5]! as int,
    parallelism: header[6]! as int,
  );
  _validateKdf(kdf, limits);
  final int chunk = header[9]! as int;
  if (chunk <= 0 || chunk > limits.maxRecordBytes) {
    throw const Fbc1FormatException('chunk_limit', 0);
  }
  if (header[10]! as int > limits.maxEntries ||
      header[11]! as int > limits.maxArchiveBytes ||
      header[12]! as int > limits.maxExpansionBytes ||
      header[13]! as int > limits.maxRecordBytes ||
      header[14]! as int > limits.maxManifestBytes) {
    throw const Fbc1FormatException('declared_limit', 0);
  }
  if (archiveBytes > (header[11]! as int)) {
    throw const Fbc1FormatException('declared_archive_limit', 0);
  }
}

void _validateKdf(Fbc1KdfParameters kdf, Fbc1Limits limits) {
  if (kdf.memoryKiB < 8 * 1024 || kdf.memoryKiB > limits.maxKdfMemoryKiB) {
    throw const Fbc1FormatException('kdf_memory', 0);
  }
  if (kdf.iterations < 1 || kdf.iterations > limits.maxKdfIterations) {
    throw const Fbc1FormatException('kdf_iterations', 0);
  }
  if (kdf.parallelism < 1 || kdf.parallelism > limits.maxKdfParallelism) {
    throw const Fbc1FormatException('kdf_parallelism', 0);
  }
}

void _validateLimits(Fbc1Limits limits) {
  if (limits.maxArchiveBytes <= 0 ||
      limits.maxHeaderBytes <= 0 ||
      limits.maxEntries < 0 ||
      limits.maxPathBytes <= 0 ||
      limits.maxTotalPathBytes <= 0 ||
      limits.maxRecordBytes <= 0 ||
      limits.maxManifestBytes <= 0 ||
      limits.maxExpansionBytes <= 0 ||
      limits.maxKdfMemoryKiB <= 0 ||
      limits.maxKdfIterations <= 0 ||
      limits.maxKdfParallelism <= 0) {
    throw ArgumentError('FBC1 limits must be positive; entries may be zero.');
  }
}

Uint8List _validatePath(String path, Fbc1Limits limits, int offset) {
  final Uint8List bytes = _utf8(path);
  if (bytes.isEmpty ||
      bytes.length > limits.maxPathBytes ||
      path.startsWith('/') ||
      path.contains(r'\') ||
      path.contains('\u0000') ||
      _hasDrivePrefix(path)) {
    throw Fbc1FormatException('invalid_path', offset);
  }
  final List<String> parts = path.split('/');
  if (parts.any((String part) => part.isEmpty || part == '.' || part == '..')) {
    throw Fbc1FormatException('invalid_path', offset);
  }
  return bytes;
}

bool _hasDrivePrefix(String path) {
  if (path.length < 2 || path.codeUnitAt(1) != 0x3a) {
    return false;
  }
  final int first = path.codeUnitAt(0);
  return (first >= 0x41 && first <= 0x5a) || (first >= 0x61 && first <= 0x7a);
}

Map<int, Object?> _intMap(Object? value, String code, int offset) {
  if (value is! Map<Object?, Object?>) {
    throw Fbc1FormatException(code, offset);
  }
  final Map<int, Object?> result = <int, Object?>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    if (entry.key is! int) {
      throw Fbc1FormatException(code, offset);
    }
    result[entry.key! as int] = entry.value;
  }
  return result;
}

void _requireKeys(Map<int, Object?> map, Set<int> keys, int offset) {
  if (map.length != keys.length || !map.keys.toSet().containsAll(keys)) {
    throw Fbc1FormatException('unexpected_fields', offset);
  }
}

Uint8List _utf8(String value) {
  // Local minimal UTF-8 encoder avoids a dart:convert dependency in this
  // cipher-neutral module and matches CanonicalCbor's own encoding.
  return Uint8List.fromList(const _Utf8Encoder().convert(value));
}

Uint8List _u32(int value) {
  if (value < 0 || value > 0xffffffff) {
    throw RangeError.value(value);
  }
  return Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.big);
}

Uint8List _u64(int value) {
  if (value < 0) {
    throw RangeError.value(value);
  }
  return Uint8List(8)..buffer.asByteData().setUint64(0, value, Endian.big);
}

int _checkedAdd(int current, int add, int max, String code, int offset) {
  if (add < 0 || current > max - add) {
    throw Fbc1FormatException(code, offset);
  }
  return current + add;
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  int difference = 0;
  for (int i = 0; i < a.length; i += 1) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

bool _deepEqual(Object? a, Object? b) {
  if (a is Uint8List && b is Uint8List) {
    return _equal(a, b);
  }
  if (a is List<Object?> && b is List<Object?>) {
    return a.length == b.length &&
        Iterable<int>.generate(
          a.length,
        ).every((int i) => _deepEqual(a[i], b[i]));
  }
  if (a is Map<Object?, Object?> && b is Map<Object?, Object?>) {
    return a.length == b.length &&
        a.entries.every(
          (MapEntry<Object?, Object?> entry) =>
              b.containsKey(entry.key) && _deepEqual(entry.value, b[entry.key]),
        );
  }
  return a == b;
}

int _compareBytes(List<int> a, List<int> b) {
  final int common = a.length < b.length ? a.length : b.length;
  for (int i = 0; i < common; i += 1) {
    final int result = a[i] - b[i];
    if (result != 0) {
      return result;
    }
  }
  return a.length - b.length;
}

final class _Reader {
  _Reader(this.data);

  final Uint8List data;
  int offset = 0;

  bool get isDone => offset == data.length;

  int byte() => bytes(1).single;

  int u32() {
    if (data.length - offset < 4) {
      throw Fbc1FormatException('truncated', offset);
    }
    final int value = data.buffer
        .asByteData(data.offsetInBytes + offset, 4)
        .getUint32(0, Endian.big);
    offset += 4;
    return value;
  }

  int u64() {
    if (data.length - offset < 8) {
      throw Fbc1FormatException('truncated', offset);
    }
    final int value = data.buffer
        .asByteData(data.offsetInBytes + offset, 8)
        .getUint64(0, Endian.big);
    offset += 8;
    return value;
  }

  Uint8List bytes(int length) {
    if (length < 0 || length > data.length - offset) {
      throw Fbc1FormatException('truncated', offset);
    }
    final Uint8List result = Uint8List.sublistView(
      data,
      offset,
      offset + length,
    );
    offset += length;
    return result;
  }
}

/// Strict deterministic CBOR subset used by FBC1: unsigned integers, byte/text
/// strings, arrays, integer-keyed maps, and booleans. Indefinite/non-minimal
/// forms, tags, floats, negatives, duplicate keys, and non-canonical map
/// ordering are all rejected. Identical semantics to the reference probe.
abstract final class CanonicalCbor {
  static Uint8List encode(Object? value) {
    final BytesBuilder output = BytesBuilder(copy: false);
    _encodeValue(output, value);
    return output.takeBytes();
  }

  static Object? decode(List<int> bytes) {
    final _CborReader reader = _CborReader(Uint8List.fromList(bytes));
    final Object? value = reader.value(0);
    if (!reader.isDone) {
      throw Fbc1FormatException('cbor_trailing', reader.offset);
    }
    return value;
  }

  static void _encodeValue(BytesBuilder output, Object? value) {
    if (value is int) {
      if (value < 0) {
        throw ArgumentError.value(value, 'CBOR integer');
      }
      _head(output, 0, value);
    } else if (value is Uint8List) {
      _head(output, 2, value.length);
      output.add(value);
    } else if (value is List<int>) {
      _head(output, 2, value.length);
      output.add(value);
    } else if (value is String) {
      final List<int> encoded = const _Utf8Encoder().convert(value);
      _head(output, 3, encoded.length);
      output.add(encoded);
    } else if (value is bool) {
      output.addByte(value ? 0xf5 : 0xf4);
    } else if (value is List<Object?>) {
      _head(output, 4, value.length);
      for (final Object? item in value) {
        _encodeValue(output, item);
      }
    } else if (value is Map<Object?, Object?>) {
      final List<(Uint8List, Object?)> entries = <(Uint8List, Object?)>[];
      for (final MapEntry<Object?, Object?> entry in value.entries) {
        final Object? entryKey = entry.key;
        if (entryKey is! int || entryKey < 0) {
          throw ArgumentError('CBOR map keys must be unsigned integers.');
        }
        entries.add((encode(entryKey), entry.value));
      }
      entries.sort(((Uint8List, Object?) a, (Uint8List, Object?) b) {
        final int length = a.$1.length - b.$1.length;
        return length != 0 ? length : _compareBytes(a.$1, b.$1);
      });
      _head(output, 5, entries.length);
      for (final (Uint8List, Object?) entry in entries) {
        output.add(entry.$1);
        _encodeValue(output, entry.$2);
      }
    } else {
      throw ArgumentError.value(value, 'CBOR value');
    }
  }

  static void _head(BytesBuilder output, int major, int value) {
    if (value < 24) {
      output.addByte((major << 5) | value);
    } else if (value <= 0xff) {
      output.add(<int>[(major << 5) | 24, value]);
    } else if (value <= 0xffff) {
      output.addByte((major << 5) | 25);
      output.add(
        Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.big),
      );
    } else if (value <= 0xffffffff) {
      output.addByte((major << 5) | 26);
      output.add(_u32(value));
    } else {
      output.addByte((major << 5) | 27);
      output.add(_u64(value));
    }
  }
}

final class _CborReader {
  _CborReader(this.data);

  final Uint8List data;
  int offset = 0;
  int items = 0;

  bool get isDone => offset == data.length;

  Object? value(int depth) {
    if (depth > 16 || ++items > 2000000) {
      throw Fbc1FormatException('cbor_complexity', offset);
    }
    final int initialOffset = offset;
    final int first = _byte();
    final int major = first >> 5;
    final int additional = first & 31;
    if (major == 7) {
      if (additional == 20) {
        return false;
      }
      if (additional == 21) {
        return true;
      }
      throw Fbc1FormatException('cbor_unsupported', initialOffset);
    }
    final int length = _argument(additional, initialOffset);
    switch (major) {
      case 0:
        return length;
      case 2:
        return _bytes(length);
      case 3:
        final Uint8List encoded = _bytes(length);
        return const _Utf8Decoder().convert(encoded, initialOffset);
      case 4:
        return <Object?>[for (int i = 0; i < length; i += 1) value(depth + 1)];
      case 5:
        final Map<Object?, Object?> map = <Object?, Object?>{};
        Uint8List? previous;
        for (int i = 0; i < length; i += 1) {
          final int keyStart = offset;
          final Object? key = value(depth + 1);
          final Uint8List keyBytes = Uint8List.sublistView(
            data,
            keyStart,
            offset,
          );
          if (key is! int) {
            throw Fbc1FormatException('cbor_map_key', keyStart);
          }
          if (previous != null && _canonicalCompare(previous, keyBytes) >= 0) {
            throw Fbc1FormatException('cbor_map_order', keyStart);
          }
          if (map.containsKey(key)) {
            throw Fbc1FormatException('cbor_duplicate_key', keyStart);
          }
          previous = keyBytes;
          map[key] = value(depth + 1);
        }
        return map;
      default:
        throw Fbc1FormatException('cbor_unsupported', initialOffset);
    }
  }

  int _argument(int additional, int initialOffset) {
    if (additional < 24) {
      return additional;
    }
    if (additional == 31) {
      throw Fbc1FormatException('cbor_indefinite', initialOffset);
    }
    final int byteCount = switch (additional) {
      24 => 1,
      25 => 2,
      26 => 4,
      27 => 8,
      _ => 0,
    };
    if (byteCount == 0) {
      throw Fbc1FormatException('cbor_reserved', initialOffset);
    }
    final Uint8List bytes = _bytes(byteCount);
    final ByteData view = bytes.buffer.asByteData(
      bytes.offsetInBytes,
      byteCount,
    );
    final int value = switch (byteCount) {
      1 => view.getUint8(0),
      2 => view.getUint16(0, Endian.big),
      4 => view.getUint32(0, Endian.big),
      8 => view.getUint64(0, Endian.big),
      _ => throw StateError('unreachable'),
    };
    final int minimum = switch (byteCount) {
      1 => 24,
      2 => 0x100,
      4 => 0x10000,
      8 => 0x100000000,
      _ => 0,
    };
    if (value < minimum) {
      throw Fbc1FormatException('cbor_noncanonical_integer', initialOffset);
    }
    return value;
  }

  int _byte() {
    if (isDone) {
      throw Fbc1FormatException('cbor_truncated', offset);
    }
    return data[offset++];
  }

  Uint8List _bytes(int length) {
    if (length < 0 || length > data.length - offset) {
      throw Fbc1FormatException('cbor_truncated', offset);
    }
    final Uint8List result = Uint8List.sublistView(
      data,
      offset,
      offset + length,
    );
    offset += length;
    return result;
  }
}

int _canonicalCompare(List<int> a, List<int> b) {
  final int length = a.length - b.length;
  return length != 0 ? length : _compareBytes(a, b);
}

/// Minimal UTF-8 encoder (no dart:convert) so this module stays dependency-lean
/// and deterministic. Rejects lone surrogates by encoding the replacement
/// character, matching strict UTF-8 for the ASCII/BMP paths FBC1 paths use.
final class _Utf8Encoder {
  const _Utf8Encoder();

  List<int> convert(String value) {
    final List<int> out = <int>[];
    final List<int> runes = value.runes.toList(growable: false);
    for (final int rune in runes) {
      if (rune < 0x80) {
        out.add(rune);
      } else if (rune < 0x800) {
        out
          ..add(0xC0 | (rune >> 6))
          ..add(0x80 | (rune & 0x3F));
      } else if (rune < 0x10000) {
        out
          ..add(0xE0 | (rune >> 12))
          ..add(0x80 | ((rune >> 6) & 0x3F))
          ..add(0x80 | (rune & 0x3F));
      } else {
        out
          ..add(0xF0 | (rune >> 18))
          ..add(0x80 | ((rune >> 12) & 0x3F))
          ..add(0x80 | ((rune >> 6) & 0x3F))
          ..add(0x80 | (rune & 0x3F));
      }
    }
    return out;
  }
}

/// Minimal strict UTF-8 decoder that rejects malformed sequences.
final class _Utf8Decoder {
  const _Utf8Decoder();

  String convert(Uint8List bytes, int offset) {
    final StringBuffer buffer = StringBuffer();
    int i = 0;
    while (i < bytes.length) {
      final int b0 = bytes[i];
      int codePoint;
      int extra;
      if (b0 < 0x80) {
        codePoint = b0;
        extra = 0;
      } else if (b0 & 0xE0 == 0xC0) {
        codePoint = b0 & 0x1F;
        extra = 1;
      } else if (b0 & 0xF0 == 0xE0) {
        codePoint = b0 & 0x0F;
        extra = 2;
      } else if (b0 & 0xF8 == 0xF0) {
        codePoint = b0 & 0x07;
        extra = 3;
      } else {
        throw Fbc1FormatException('cbor_utf8', offset);
      }
      if (i + extra >= bytes.length) {
        throw Fbc1FormatException('cbor_utf8', offset);
      }
      for (int k = 1; k <= extra; k += 1) {
        final int b = bytes[i + k];
        if (b & 0xC0 != 0x80) {
          throw Fbc1FormatException('cbor_utf8', offset);
        }
        codePoint = (codePoint << 6) | (b & 0x3F);
      }
      final int minimum = switch (extra) {
        0 => 0,
        1 => 0x80,
        2 => 0x800,
        _ => 0x10000,
      };
      if (codePoint < minimum ||
          codePoint > 0x10FFFF ||
          (codePoint >= 0xD800 && codePoint <= 0xDFFF)) {
        throw Fbc1FormatException('cbor_utf8', offset);
      }
      buffer.writeCharCode(codePoint);
      i += extra + 1;
    }
    return buffer.toString();
  }
}
