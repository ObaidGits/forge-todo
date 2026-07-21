import 'dart:typed_data';

/// The kind of filesystem object an opened descriptor refers to.
enum SourceFileType { regular, symlink, directory, other }

/// The authoritative stat of an *opened descriptor* (fstat semantics), not a
/// re-stat of a path. The pipeline validates this to defeat TOCTOU races: a
/// symlink or special file swapped in after a path check is still caught
/// because the descriptor that was actually opened is what gets inspected.
final class OpenedSourceStat {
  const OpenedSourceStat({required this.type, required this.size});

  final SourceFileType type;
  final int size;
}

/// An opened external source file, bound to the descriptor that was opened.
///
/// [stat] reflects the opened descriptor. [readAll] reads the content of that
/// same descriptor, so if the underlying path was swapped between open and
/// read, the descriptor still refers to the originally-opened object (or the
/// adapter reports the change via [OpenedSource.contentChangedSinceOpen]).
abstract interface class OpenedSource {
  OpenedSourceStat get stat;

  /// True when the adapter detected that the opened descriptor no longer refers
  /// to the same content it was opened against (a TOCTOU replacement).
  bool get contentChangedSinceOpen;

  Future<Uint8List> readAll();

  Future<void> close();
}

/// A staging handle for the security-first write pipeline (R-NOTE-006).
///
/// The pipeline writes ciphertext to a private staging path, [sync]s it durably
/// to disk, then [publish]es it with an atomic rename and a directory fsync so a
/// crash never exposes a half-written file. [discard] removes the staging file
/// on any rejection or crash-cleanup path.
abstract interface class StagedFile {
  Future<void> write(List<int> bytes);

  /// Flushes and fsyncs the staged file's data to durable storage.
  Future<void> sync();

  /// Atomically renames the staged file to its final managed path token and
  /// fsyncs the containing directory (durable publication).
  Future<void> publish();

  /// Removes the staging file. Idempotent.
  Future<void> discard();
}

/// A decrypted temporary file materialised for a confirmed external open
/// (R-NOTE-006, R-SEC-005). It lives in a controlled location and is deleted by
/// [dispose]; the grant is least-lived.
abstract interface class ExternalTempFile {
  /// Absolute path handed to the platform opener under a least-lived grant.
  String get path;

  Future<void> dispose();
}

/// Filesystem boundary for managed attachments.
///
/// This port isolates every filesystem operation the pipeline needs — opening a
/// source under TOCTOU-safe discipline, staging with fsync + atomic rename,
/// reading/deleting published files, and materialising a cleaned-up external
/// temp file. The production adapter is dart:io (regular-file/no-link checks,
/// open-then-fstat, RandomAccessFile flush, atomic rename, best-effort
/// directory fsync); tests inject a deterministic in-memory adapter that can
/// simulate symlink sources, TOCTOU replacement, quota/disk behaviour, and that
/// records publication ordering. No cipher or domain concern leaks here.
abstract interface class ManagedFileSystem {
  /// Opens [sourcePath] for import. The returned handle is bound to the opened
  /// descriptor; callers MUST validate [OpenedSource.stat] (not a pre-check of
  /// the path) before trusting the content.
  Future<OpenedSource> openSource(String sourcePath);

  /// Begins staging the managed file that will be published at [pathToken].
  Future<StagedFile> beginStaging(String pathToken);

  /// Whether a published managed file exists for [pathToken].
  Future<bool> managedExists(String pathToken);

  /// Reads the published ciphertext for [pathToken].
  Future<Uint8List> readManaged(String pathToken);

  /// Deletes the published managed file for [pathToken] and fsyncs the
  /// directory. Idempotent; missing files are treated as already deleted.
  Future<void> deleteManaged(String pathToken);

  /// Writes decrypted [bytes] to a controlled temp file for a confirmed
  /// external open, returning a handle whose [ExternalTempFile.dispose] removes
  /// it (least-lived grant, R-SEC-005).
  Future<ExternalTempFile> writeExternalTemp({
    required String suggestedName,
    required List<int> bytes,
  });
}
