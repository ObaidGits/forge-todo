import 'package:forge/features/backup/domain/human_readable_export.dart';
import 'package:forge/features/backup/domain/portable_tables.dart';

/// What the importer will do with a single incoming row.
enum ImportDisposition {
  /// The incoming ID does not exist locally; insert it unchanged.
  addNew,

  /// The incoming row is byte-for-byte identical to an existing live row;
  /// skip it (no write, no duplicate).
  exactMatchSkip,

  /// The incoming ID collides with a *different* existing live row; the
  /// incoming row is remapped to a fresh ID and all references follow
  /// (`R-GEN-003`). Import never silently overwrites.
  remapCollision,

  /// The incoming ID collides with an existing *tombstone*; the incoming row
  /// is remapped to a fresh ID so the tombstone can never resurrect
  /// (`R-GEN-003`, Property 6). Import never revives a deleted record.
  remapTombstoneBlocked,

  /// The incoming row is itself a tombstone (a deletion marker); it is skipped
  /// entirely. A human-readable import brings data in, never deletions.
  incomingTombstoneSkip,
}

/// One planned row within an [ImportPlan]. Content is not carried here; the
/// committer looks the row up by [table]/[originalId] and applies [finalId]
/// plus the plan's reference remaps.
final class ImportRowPlan {
  const ImportRowPlan({
    required this.table,
    required this.originalId,
    required this.finalId,
    required this.disposition,
  });

  final String table;
  final String originalId;
  final String finalId;
  final ImportDisposition disposition;

  bool get writes =>
      disposition == ImportDisposition.addNew ||
      disposition == ImportDisposition.remapCollision ||
      disposition == ImportDisposition.remapTombstoneBlocked;

  @override
  bool operator ==(Object other) =>
      other is ImportRowPlan &&
      other.table == table &&
      other.originalId == originalId &&
      other.finalId == finalId &&
      other.disposition == disposition;

  @override
  int get hashCode => Object.hash(table, originalId, finalId, disposition);
}

/// The complete, previewable import plan (`R-BACKUP-005` collision-remap
/// preview). It is computed before any write so the user can inspect exactly
/// how colliding IDs will be remapped and how many rows are added, skipped, or
/// blocked from resurrecting a tombstone.
final class ImportPlan {
  ImportPlan({
    required List<ImportRowPlan> rows,
    required Map<String, String> remaps,
  }) : rows = List<ImportRowPlan>.unmodifiable(rows),
       remaps = Map<String, String>.unmodifiable(remaps);

  final List<ImportRowPlan> rows;

  /// Original-ID → new-ID for every remapped row. Reference fields are rewritten
  /// against this map at commit time so links stay intact (`R-GEN-003`).
  final Map<String, String> remaps;

  Iterable<ImportRowPlan> get _byDisposition => rows;

  int count(ImportDisposition disposition) => _byDisposition
      .where((ImportRowPlan r) => r.disposition == disposition)
      .length;

  int get addedCount => count(ImportDisposition.addNew);
  int get exactMatchCount => count(ImportDisposition.exactMatchSkip);
  int get collisionRemapCount => count(ImportDisposition.remapCollision);
  int get tombstoneBlockedCount =>
      count(ImportDisposition.remapTombstoneBlocked);
  int get incomingTombstoneSkippedCount =>
      count(ImportDisposition.incomingTombstoneSkip);

  int get writeCount => rows.where((ImportRowPlan r) => r.writes).length;

  bool get hasRemaps => remaps.isNotEmpty;
}

/// A minimal projection of an existing local row the planner needs: its content
/// cells and whether it is a tombstone. The importer supplies these from the
/// live generation without exposing the database to the pure planner.
final class ExistingRow {
  const ExistingRow({required this.values, required this.isTombstone});

  final Map<String, String?> values;
  final bool isTombstone;
}

/// Mints fresh IDs for remapped rows. Infrastructure wires the UUIDv7
/// generator; tests wire a deterministic sequence.
abstract interface class ImportIdMinter {
  String mint();
}

/// Computes the collision-remap preview for a human-readable import
/// (`R-BACKUP-005`, `R-GEN-003`).
///
/// Rules, applied per row in document order:
/// 1. An incoming row that is itself a tombstone is skipped
///    ([ImportDisposition.incomingTombstoneSkip]).
/// 2. No local row with that ID → insert unchanged
///    ([ImportDisposition.addNew]).
/// 3. Local row is a tombstone → remap to a fresh ID so the deletion can never
///    resurrect ([ImportDisposition.remapTombstoneBlocked]).
/// 4. Local live row identical in content → skip
///    ([ImportDisposition.exactMatchSkip]).
/// 5. Local live row differs → remap to a fresh ID
///    ([ImportDisposition.remapCollision]); import never overwrites.
///
/// Every remap records original→new so the committer can rewrite references.
final class ImportPlanner {
  const ImportPlanner({this.tables = defaultPortableTables});

  final List<PortableTable> tables;

  ImportPlan plan({
    required ExportDocument document,
    required Map<String, Map<String, ExistingRow>> existing,
    required ImportIdMinter minter,
  }) {
    final Map<String, PortableTable> byName = <String, PortableTable>{
      for (final PortableTable t in tables) t.name: t,
    };
    final List<ImportRowPlan> rows = <ImportRowPlan>[];
    final Map<String, String> remaps = <String, String>{};

    for (final ExportTable table in document.tables) {
      final PortableTable? config = byName[table.name];
      if (config == null) {
        // Unknown/non-portable table: ignore rather than trust arbitrary input.
        continue;
      }
      final Map<String, ExistingRow> localRows =
          existing[table.name] ?? const <String, ExistingRow>{};
      for (final Map<String, String?> row in table.rows) {
        final String? originalId = row[config.primaryKeyColumn];
        if (originalId == null || originalId.isEmpty) {
          throw HumanReadableFormatException(
            'missing_primary_key',
            '${table.name}.${config.primaryKeyColumn}',
          );
        }
        if (_isTombstone(row, config)) {
          rows.add(
            ImportRowPlan(
              table: table.name,
              originalId: originalId,
              finalId: originalId,
              disposition: ImportDisposition.incomingTombstoneSkip,
            ),
          );
          continue;
        }
        final ExistingRow? local = localRows[originalId];
        if (local == null) {
          rows.add(
            ImportRowPlan(
              table: table.name,
              originalId: originalId,
              finalId: originalId,
              disposition: ImportDisposition.addNew,
            ),
          );
          continue;
        }
        if (local.isTombstone) {
          final String newId = minter.mint();
          remaps[originalId] = newId;
          rows.add(
            ImportRowPlan(
              table: table.name,
              originalId: originalId,
              finalId: newId,
              disposition: ImportDisposition.remapTombstoneBlocked,
            ),
          );
          continue;
        }
        if (_contentEquals(local.values, row)) {
          rows.add(
            ImportRowPlan(
              table: table.name,
              originalId: originalId,
              finalId: originalId,
              disposition: ImportDisposition.exactMatchSkip,
            ),
          );
          continue;
        }
        final String newId = minter.mint();
        remaps[originalId] = newId;
        rows.add(
          ImportRowPlan(
            table: table.name,
            originalId: originalId,
            finalId: newId,
            disposition: ImportDisposition.remapCollision,
          ),
        );
      }
    }
    return ImportPlan(rows: rows, remaps: remaps);
  }

  bool _isTombstone(Map<String, String?> row, PortableTable config) {
    final String? column = config.tombstoneColumn;
    if (column == null) {
      return false;
    }
    final String? value = row[column];
    return value != null && value.isNotEmpty;
  }

  bool _contentEquals(
    Map<String, String?> local,
    Map<String, String?> incoming,
  ) {
    // Compare on the incoming columns; an exact match means every provided cell
    // equals the stored value. Extra local-only columns (defaults) do not make
    // a re-import a "difference".
    for (final MapEntry<String, String?> entry in incoming.entries) {
      if (!local.containsKey(entry.key)) {
        return false;
      }
      if (local[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }
}
