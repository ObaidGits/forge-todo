import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';
import 'package:forge/app/infrastructure/database/migration/resumable_backfill.dart';

/// A single failed verification check, named for redacted diagnostics.
final class VerificationFailure {
  const VerificationFailure(this.check, this.detail);

  final String check;
  final String detail;

  @override
  String toString() => '$check: $detail';
}

/// Aggregate result of the post-backfill verification suite.
final class VerificationReport {
  VerificationReport(List<VerificationFailure> failures)
    : failures = List<VerificationFailure>.unmodifiable(failures);

  final List<VerificationFailure> failures;

  bool get passed => failures.isEmpty;

  String? get firstFailure => passed ? null : failures.first.toString();
}

/// Verifies that a freshly backfilled shadow generation is trustworthy before
/// it may be activated.
///
/// Checks (data-model §5.3): row counts preserved for every backfilled table,
/// referential integrity (`foreign_key_check`), structural integrity
/// (`integrity_check`), and FTS integrity/rebuild consistency. Any failure
/// keeps the prior generation live; it never resets data.
// Not `final`: tests substitute a fault-injecting verifier to exercise the
// migrator's post-backfill rollback branch.
class MigrationVerifier {
  const MigrationVerifier({this.ftsVerifier = const FtsIntegrityVerifier()});

  final FtsIntegrityVerifier ftsVerifier;

  Future<VerificationReport> verify({
    required MigrationConnection source,
    required MigrationConnection shadow,
    required List<String> preservedTables,
  }) async {
    final List<VerificationFailure> failures = <VerificationFailure>[];

    // 1. Row counts preserved for every table copied verbatim.
    for (final String table in preservedTables) {
      final int sourceCount = await source.countRows(table);
      final int shadowCount = await shadow.countRows(table);
      if (sourceCount != shadowCount) {
        failures.add(
          VerificationFailure(
            'row_count',
            '$table expected $sourceCount, found $shadowCount',
          ),
        );
      }
    }

    // 2. Structural integrity.
    final List<Map<String, Object?>> integrity = await shadow.select(
      'PRAGMA integrity_check',
    );
    final String integrityResult = integrity.isEmpty
        ? 'empty'
        : integrity.first.values.first.toString();
    if (integrityResult != 'ok') {
      failures.add(VerificationFailure('integrity_check', integrityResult));
    }

    // 3. Referential integrity: foreign_key_check yields one row per violation.
    final List<Map<String, Object?>> fkViolations = await shadow.select(
      'PRAGMA foreign_key_check',
    );
    if (fkViolations.isNotEmpty) {
      failures.add(
        VerificationFailure(
          'foreign_key_check',
          '${fkViolations.length} violation(s)',
        ),
      );
    }

    // 4. FTS integrity / rebuild consistency.
    final FtsIntegrityReport fts = await ftsVerifier.verify(shadow);
    failures.addAll(fts.failures);

    return VerificationReport(failures);
  }
}

/// Report from [FtsIntegrityVerifier].
final class FtsIntegrityReport {
  FtsIntegrityReport({
    required this.ftsTables,
    required List<VerificationFailure> failures,
  }) : failures = List<VerificationFailure>.unmodifiable(failures);

  final List<String> ftsTables;
  final List<VerificationFailure> failures;

  bool get passed => failures.isEmpty;
}

/// Verifies every FTS5 index in a store.
///
/// For each FTS5 table it runs the built-in `integrity-check` command. The
/// strong form (`rank = 1`) additionally cross-checks an external-content index
/// against its content table, so a shadow index that drifted from the
/// regenerated source rows is caught before activation (data-model §4,
/// testing §5). The verifier deliberately does NOT `rebuild` here: a rebuild
/// would silently regenerate the index from content and mask exactly the
/// divergence we are checking for. Rebuild-from-source is a migration *step*,
/// not a verification step.
final class FtsIntegrityVerifier {
  const FtsIntegrityVerifier();

  Future<FtsIntegrityReport> verify(MigrationConnection connection) async {
    final List<String> ftsTables = await _discoverFtsTables(connection);
    final List<VerificationFailure> failures = <VerificationFailure>[];
    for (final String table in ftsTables) {
      try {
        await _integrityCheck(connection, table);
      } on Object catch (error) {
        failures.add(VerificationFailure('fts_integrity', '$table: $error'));
      }
    }
    return FtsIntegrityReport(ftsTables: ftsTables, failures: failures);
  }

  Future<void> _integrityCheck(
    MigrationConnection connection,
    String table,
  ) async {
    // Prefer the strong check that also compares an external-content index to
    // its content table; fall back to the internal-only form on older builds.
    try {
      await connection.execute(
        'INSERT INTO "$table"("$table", rank) VALUES (\'integrity-check\', 1)',
      );
      return;
    } on MigrationConnectionException {
      rethrow;
    } on Object catch (error) {
      final String message = error.toString().toLowerCase();
      final bool isConsistencyError =
          message.contains('corrupt') || message.contains('database disk');
      if (isConsistencyError) {
        rethrow;
      }
      // Syntax not supported (older SQLite): use the internal-only form.
      await connection.execute(
        'INSERT INTO "$table"("$table") VALUES (\'integrity-check\')',
      );
    }
  }

  Future<List<String>> _discoverFtsTables(
    MigrationConnection connection,
  ) async {
    final List<Map<String, Object?>> rows = await connection.select(
      "SELECT name, sql FROM sqlite_master WHERE type = 'table' "
      "AND sql IS NOT NULL AND name NOT LIKE 'sqlite_%' "
      "AND name <> '$kBackfillProgressTable'",
    );
    final List<String> tables = <String>[];
    for (final Map<String, Object?> row in rows) {
      final String sql = (row['sql']! as String).toLowerCase();
      if (sql.contains('using fts5')) {
        tables.add(row['name']! as String);
      }
    }
    tables.sort();
    return tables;
  }
}
