import 'dart:convert';
import 'dart:io';

/// Durable, restart-safe record of an in-flight shadow migration.
///
/// The journal lives beside the active-generation pointer (outside every
/// generation). Its purpose is cleanup, not activation: the pointer alone
/// decides which generation is live. If startup finds a journal whose
/// `activated` flag is false, the migration was interrupted — the listed shadow
/// directories are abandoned and safe to delete, and the prior generation
/// (still referenced by the untouched pointer) opens normally (design §12).
final class MigrationJournalEntry {
  MigrationJournalEntry({
    required this.sourceDirectoryName,
    required this.sourceSchemaVersion,
    required this.targetSchemaVersion,
    required List<String> createdDirectoryNames,
    required this.activated,
    this.finalDirectoryName,
  }) : createdDirectoryNames = List<String>.unmodifiable(createdDirectoryNames);

  final String sourceDirectoryName;
  final int sourceSchemaVersion;
  final int targetSchemaVersion;
  final List<String> createdDirectoryNames;
  final bool activated;
  final String? finalDirectoryName;

  MigrationJournalEntry copyWith({
    List<String>? createdDirectoryNames,
    bool? activated,
    String? finalDirectoryName,
  }) => MigrationJournalEntry(
    sourceDirectoryName: sourceDirectoryName,
    sourceSchemaVersion: sourceSchemaVersion,
    targetSchemaVersion: targetSchemaVersion,
    createdDirectoryNames: createdDirectoryNames ?? this.createdDirectoryNames,
    activated: activated ?? this.activated,
    finalDirectoryName: finalDirectoryName ?? this.finalDirectoryName,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'source_directory_name': sourceDirectoryName,
    'source_schema_version': sourceSchemaVersion,
    'target_schema_version': targetSchemaVersion,
    'created_directory_names': createdDirectoryNames,
    'activated': activated,
    'final_directory_name': finalDirectoryName,
  };

  static MigrationJournalEntry fromJson(Map<String, Object?> json) =>
      MigrationJournalEntry(
        sourceDirectoryName: json['source_directory_name']! as String,
        sourceSchemaVersion: json['source_schema_version']! as int,
        targetSchemaVersion: json['target_schema_version']! as int,
        createdDirectoryNames:
            (json['created_directory_names']! as List<Object?>).cast<String>(),
        activated: json['activated']! as bool,
        finalDirectoryName: json['final_directory_name'] as String?,
      );
}

/// Reads and atomically replaces the single migration journal file.
final class MigrationJournal {
  const MigrationJournal({required this.journalFile});

  final File journalFile;

  Future<MigrationJournalEntry?> read() async {
    if (!await journalFile.exists()) {
      return null;
    }
    final Object? decoded = jsonDecode(await journalFile.readAsString());
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    return MigrationJournalEntry.fromJson(decoded);
  }

  Future<void> write(MigrationJournalEntry entry) async {
    await journalFile.parent.create(recursive: true);
    final File temp = File('${journalFile.path}.tmp');
    await temp.writeAsString(jsonEncode(entry.toJson()), flush: true);
    await temp.rename(journalFile.path);
  }

  Future<void> clear() async {
    if (await journalFile.exists()) {
      await journalFile.delete();
    }
  }
}
