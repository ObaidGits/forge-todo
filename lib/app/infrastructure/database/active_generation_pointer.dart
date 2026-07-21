import 'dart:convert';
import 'dart:io';

import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/id.dart';

/// A resolved active-generation record. The generation directory holds the
/// encrypted store; the pointer itself lives *outside* every generation so it
/// can be swapped atomically without ever exposing a half-switched store.
final class ActiveGenerationRecord {
  const ActiveGenerationRecord({
    required this.generation,
    required this.directoryName,
  });

  final DatabaseGeneration generation;

  /// Directory (relative to the pointer's base directory) that contains this
  /// generation's encrypted store.
  final String directoryName;

  Map<String, Object?> toJson() => <String, Object?>{
    'generation_id': generation.id.value,
    'schema_version': generation.schemaVersion,
    'directory_name': directoryName,
  };

  static ActiveGenerationRecord fromJson(Map<String, Object?> json) {
    return ActiveGenerationRecord(
      generation: DatabaseGeneration(
        id: GenerationId(json['generation_id']! as String),
        schemaVersion: json['schema_version']! as int,
      ),
      directoryName: json['directory_name']! as String,
    );
  }
}

/// Raised when the pointer file exists but cannot be parsed. This is a
/// Recovery-Mode signal, never a trigger to reset data.
final class ActiveGenerationPointerCorrupt implements Exception {
  const ActiveGenerationPointerCorrupt(this.reason);

  final String reason;

  @override
  String toString() => 'ActiveGenerationPointerCorrupt($reason)';
}

/// Reads and atomically replaces the single active-generation pointer.
final class ActiveGenerationPointer {
  ActiveGenerationPointer({required this.pointerFile});

  final File pointerFile;

  /// Returns the current pointer, or null when no store has been provisioned.
  ///
  /// Throws [ActiveGenerationPointerCorrupt] when a present pointer is
  /// unreadable so the caller can enter Recovery Mode rather than guess.
  Future<ActiveGenerationRecord?> read() async {
    if (!await pointerFile.exists()) {
      return null;
    }
    final String raw;
    try {
      raw = await pointerFile.readAsString();
    } on FileSystemException catch (error) {
      throw ActiveGenerationPointerCorrupt('unreadable: ${error.osError}');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (error) {
      throw ActiveGenerationPointerCorrupt('malformed: ${error.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const ActiveGenerationPointerCorrupt('not an object');
    }
    try {
      return ActiveGenerationRecord.fromJson(decoded);
    } on Object catch (error) {
      throw ActiveGenerationPointerCorrupt('invalid fields: $error');
    }
  }

  /// Atomically replaces the pointer with [record].
  ///
  /// The write goes to a sibling temp file that is then renamed over the
  /// pointer. Rename is atomic within a filesystem, so a concurrent or
  /// crash-interrupted switch always leaves either the old or the new pointer,
  /// never a blend.
  Future<void> switchTo(ActiveGenerationRecord record) async {
    await pointerFile.parent.create(recursive: true);
    final File temp = File(
      '${pointerFile.path}.tmp-${record.generation.id.value}',
    );
    await temp.writeAsString(jsonEncode(record.toJson()), flush: true);
    await temp.rename(pointerFile.path);
  }
}
