import 'dart:typed_data';

import 'package:forge/features/notes/application/attachments/managed_file_system.dart';

/// A registered external source for the in-memory managed filesystem.
final class FakeSource {
  FakeSource({
    required this.type,
    required this.bytes,
    this.replacementOnRead,
    int? statSize,
  }) : statSize = statSize ?? bytes.length;

  final SourceFileType type;
  final Uint8List bytes;

  /// The size reported by the opened descriptor's stat. For a *sparse* file
  /// this deliberately disagrees with [bytes].length: a hole-punched file can
  /// stat far larger (or, when the stat lies, far smaller) than the bytes that
  /// actually stream out. The pipeline must trust the streamed byte count for
  /// quota, never the stat size.
  final int statSize;

  /// When non-null, [OpenedSource.readAll] returns these bytes and flags a
  /// TOCTOU replacement (the content changed between open and read).
  final Uint8List? replacementOnRead;
}

/// Deterministic in-memory [ManagedFileSystem] that simulates symlink/special
/// sources, TOCTOU replacement, publication ordering, and external temp files.
///
/// It records the exact sequence of durability-relevant operations in [log] so
/// tests can assert that a staged file is fsynced before it is atomically
/// published (fsync-before-rename), and that deletions occur after journaling.
final class FakeManagedFileSystem implements ManagedFileSystem {
  final Map<String, FakeSource> sources = <String, FakeSource>{};
  final Map<String, Uint8List> published = <String, Uint8List>{};
  final Map<String, Uint8List> _staging = <String, Uint8List>{};
  final List<String> log = <String>[];
  final List<String> externalTemps = <String>[];

  /// When true, [StagedFile.publish] throws to simulate a crash during publish.
  bool failPublish = false;

  /// When true, [deleteManaged] throws to simulate a crash after the deletion
  /// has been journaled but before the file is removed.
  bool failDelete = false;
  int _tempCounter = 0;

  void registerRegularSource(String path, List<int> bytes) {
    sources[path] = FakeSource(
      type: SourceFileType.regular,
      bytes: Uint8List.fromList(bytes),
    );
  }

  /// Registers a *sparse* regular file: the opened descriptor stats at
  /// [statSize] while [bytes] is what actually streams out. Used to prove the
  /// quota is enforced on the true streamed byte count, never the stat size.
  void registerSparseSource(
    String path, {
    required int statSize,
    required List<int> bytes,
  }) {
    sources[path] = FakeSource(
      type: SourceFileType.regular,
      bytes: Uint8List.fromList(bytes),
      statSize: statSize,
    );
  }

  void registerSymlinkSource(String path, {List<int> bytes = const <int>[]}) {
    sources[path] = FakeSource(
      type: SourceFileType.symlink,
      bytes: Uint8List.fromList(bytes),
    );
  }

  void registerSpecialSource(
    String path, {
    SourceFileType type = SourceFileType.other,
  }) {
    sources[path] = FakeSource(type: type, bytes: Uint8List(0));
  }

  /// Registers a source whose content is swapped between open and read (TOCTOU).
  void registerToctouSource(
    String path, {
    required List<int> atOpen,
    required List<int> atRead,
  }) {
    sources[path] = FakeSource(
      type: SourceFileType.regular,
      bytes: Uint8List.fromList(atOpen),
      replacementOnRead: Uint8List.fromList(atRead),
    );
  }

  @override
  Future<OpenedSource> openSource(String sourcePath) async {
    final FakeSource? source = sources[sourcePath];
    if (source == null) {
      throw StateError('No fake source registered at $sourcePath');
    }
    log.add('open:$sourcePath');
    return _FakeOpenedSource(source);
  }

  @override
  Future<StagedFile> beginStaging(String pathToken) async {
    log.add('stage.begin:$pathToken');
    return _FakeStagedFile(this, pathToken);
  }

  @override
  Future<bool> managedExists(String pathToken) async =>
      published.containsKey(pathToken);

  @override
  Future<Uint8List> readManaged(String pathToken) async {
    final Uint8List? bytes = published[pathToken];
    if (bytes == null) {
      throw StateError('No published file for $pathToken');
    }
    return bytes;
  }

  @override
  Future<void> deleteManaged(String pathToken) async {
    if (failDelete) {
      throw StateError('simulated delete crash');
    }
    log.add('delete:$pathToken');
    published.remove(pathToken);
  }

  @override
  Future<ExternalTempFile> writeExternalTemp({
    required String suggestedName,
    required List<int> bytes,
  }) async {
    final String path = '/tmp/forge-att-${_tempCounter++}/$suggestedName';
    externalTemps.add(path);
    log.add('extern.write:$path');
    return _FakeExternalTempFile(this, path);
  }
}

final class _FakeOpenedSource implements OpenedSource {
  _FakeOpenedSource(this._source);

  final FakeSource _source;
  bool _changed = false;

  @override
  OpenedSourceStat get stat =>
      OpenedSourceStat(type: _source.type, size: _source.statSize);

  @override
  bool get contentChangedSinceOpen => _changed;

  @override
  Future<Uint8List> readAll() async {
    final Uint8List? replacement = _source.replacementOnRead;
    if (replacement != null) {
      _changed = true;
      return replacement;
    }
    return _source.bytes;
  }

  @override
  Future<void> close() async {}
}

final class _FakeStagedFile implements StagedFile {
  _FakeStagedFile(this._fs, this._token);

  final FakeManagedFileSystem _fs;
  final String _token;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  bool _synced = false;

  @override
  Future<void> write(List<int> bytes) async {
    _fs.log.add('stage.write:$_token');
    _buffer.add(bytes);
    _fs._staging[_token] = _buffer.toBytes();
  }

  @override
  Future<void> sync() async {
    _fs.log.add('stage.sync:$_token');
    _synced = true;
  }

  @override
  Future<void> publish() async {
    if (_fs.failPublish) {
      throw StateError('simulated publish crash');
    }
    // Enforce the durability discipline: the staged data must be fsynced before
    // the atomic rename that publishes it.
    if (!_synced) {
      throw StateError('publish before sync (fsync-before-rename violated)');
    }
    _fs.log.add('stage.publish:$_token');
    final Uint8List? staged = _fs._staging.remove(_token);
    if (staged == null) {
      throw StateError('nothing staged for $_token');
    }
    _fs.published[_token] = staged;
  }

  @override
  Future<void> discard() async {
    _fs.log.add('stage.discard:$_token');
    _fs._staging.remove(_token);
  }
}

final class _FakeExternalTempFile implements ExternalTempFile {
  _FakeExternalTempFile(this._fs, this.path);

  final FakeManagedFileSystem _fs;

  @override
  final String path;

  @override
  Future<void> dispose() async {
    _fs.log.add('extern.dispose:$path');
    _fs.externalTemps.remove(path);
  }
}
