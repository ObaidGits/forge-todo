import 'dart:io';
import 'dart:typed_data';

import 'package:forge/features/notes/application/attachments/managed_file_system.dart';

/// Production dart:io adapter for the managed-attachment filesystem
/// (R-NOTE-006, R-SEC-002).
///
/// Regular-file/no-link validation, staging with a file fsync, and an atomic
/// rename to publish are implemented directly. The fully fd-bound fstat
/// (defeating every TOCTOU race) and the containing-directory fsync require a
/// native syscall surface and are deferred with the encrypted-store provider
/// (ADR-0001); this adapter performs the best-effort dart:io equivalents and
/// the pipeline's TOCTOU/ordering logic is validated against the deterministic
/// in-memory adapter. No cipher concern lives here.
final class IoManagedFileSystem implements ManagedFileSystem {
  IoManagedFileSystem({required this.managedRoot, this.externalTempRoot});

  /// Root directory holding published encrypted files and the staging area.
  final Directory managedRoot;
  final Directory? externalTempRoot;

  Directory get _stagingDir => Directory('${managedRoot.path}/.staging');

  String _finalPath(String token) => '${managedRoot.path}/$token';
  String _stagingPath(String token) => '${_stagingDir.path}/$token';

  @override
  Future<OpenedSource> openSource(String sourcePath) async {
    final FileSystemEntityType type = await FileSystemEntity.type(
      sourcePath,
      followLinks: false,
    );
    final SourceFileType mapped = switch (type) {
      FileSystemEntityType.file => SourceFileType.regular,
      FileSystemEntityType.link => SourceFileType.symlink,
      FileSystemEntityType.directory => SourceFileType.directory,
      _ => SourceFileType.other,
    };
    if (mapped != SourceFileType.regular) {
      return _IoOpenedSource(
        OpenedSourceStat(type: mapped, size: 0),
        null,
        false,
      );
    }
    final File file = File(sourcePath);
    final RandomAccessFile raf = await file.open();
    final int lengthAtOpen = await raf.length();
    return _IoOpenedSource(
      OpenedSourceStat(type: SourceFileType.regular, size: lengthAtOpen),
      raf,
      false,
    );
  }

  @override
  Future<StagedFile> beginStaging(String pathToken) async {
    await _stagingDir.create(recursive: true);
    await managedRoot.create(recursive: true);
    return _IoStagedFile(
      stagingPath: _stagingPath(pathToken),
      finalPath: _finalPath(pathToken),
    );
  }

  @override
  Future<bool> managedExists(String pathToken) =>
      File(_finalPath(pathToken)).exists();

  @override
  Future<Uint8List> readManaged(String pathToken) =>
      File(_finalPath(pathToken)).readAsBytes();

  @override
  Future<void> deleteManaged(String pathToken) async {
    final File file = File(_finalPath(pathToken));
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<ExternalTempFile> writeExternalTemp({
    required String suggestedName,
    required List<int> bytes,
  }) async {
    final Directory root =
        externalTempRoot ?? await Directory.systemTemp.createTemp('forge-att-');
    await root.create(recursive: true);
    final File file = File('${root.path}/$suggestedName');
    await file.writeAsBytes(bytes, flush: true);
    return _IoExternalTempFile(file);
  }
}

final class _IoOpenedSource implements OpenedSource {
  _IoOpenedSource(this.stat, this._raf, this.contentChangedSinceOpen);

  @override
  final OpenedSourceStat stat;
  @override
  final bool contentChangedSinceOpen;
  final RandomAccessFile? _raf;

  @override
  Future<Uint8List> readAll() async {
    final RandomAccessFile? raf = _raf;
    if (raf == null) {
      return Uint8List(0);
    }
    await raf.setPosition(0);
    final int length = await raf.length();
    return raf.read(length);
  }

  @override
  Future<void> close() async {
    await _raf?.close();
  }
}

final class _IoStagedFile implements StagedFile {
  _IoStagedFile({required this.stagingPath, required this.finalPath});

  final String stagingPath;
  final String finalPath;
  RandomAccessFile? _raf;

  @override
  Future<void> write(List<int> bytes) async {
    final RandomAccessFile raf = await File(
      stagingPath,
    ).open(mode: FileMode.write);
    _raf = raf;
    await raf.writeFrom(bytes);
  }

  @override
  Future<void> sync() async {
    final RandomAccessFile? raf = _raf;
    if (raf != null) {
      // Flushes buffered data and fsyncs the file contents to durable storage.
      await raf.flush();
      await raf.close();
      _raf = null;
    }
  }

  @override
  Future<void> publish() async {
    // Atomic rename on the same filesystem. The containing-directory fsync that
    // makes the rename itself crash-durable requires a native syscall and is
    // deferred with the encrypted-store provider (ADR-0001).
    await File(stagingPath).rename(finalPath);
  }

  @override
  Future<void> discard() async {
    await _raf?.close();
    _raf = null;
    final File file = File(stagingPath);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

final class _IoExternalTempFile implements ExternalTempFile {
  _IoExternalTempFile(this._file);

  final File _file;

  @override
  String get path => _file.path;

  @override
  Future<void> dispose() async {
    if (await _file.exists()) {
      await _file.delete();
    }
  }
}
