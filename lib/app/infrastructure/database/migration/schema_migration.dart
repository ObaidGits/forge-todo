import 'package:forge/app/infrastructure/database/migration/migration_connection.dart';

/// Transforms one source row into the shadow-schema row(s) that replace it.
///
/// The default identity transform copies every column verbatim, which is the
/// correct behaviour for additive changes and for tables an incompatible
/// migration leaves structurally unchanged. Column renames, splits, and type
/// normalisations supply a custom transform.
typedef RowTransform = Map<String, Object?> Function(Map<String, Object?> row);

Map<String, Object?> _identity(Map<String, Object?> row) => row;

/// One table to copy from the source generation into the shadow generation.
///
/// [orderByColumn] must be unique and sortable; it is the resumable backfill
/// cursor. Text UUIDv7 keys sort chronologically and work directly.
final class BackfillTable {
  const BackfillTable({
    required this.name,
    required this.orderByColumn,
    this.transform = _identity,
    this.verifyRowCount = true,
  });

  final String name;
  final String orderByColumn;
  final RowTransform transform;

  /// Whether post-backfill verification asserts source and shadow have equal
  /// row counts. Disable only for a transform that legitimately changes
  /// cardinality (e.g. a split).
  final bool verifyRowCount;
}

/// A resolved migration from a supported baseline to the target schema version.
///
/// An *additive* plan (`requiresShadowGeneration == false`) applies small DDL
/// transactionally in place. An *incompatible* plan builds a complete unexposed
/// shadow generation, backfills it in bounded resumable batches, verifies it,
/// and activates it atomically (data-model §5.3, design §12).
final class MigrationPlan {
  MigrationPlan({
    required this.sourceVersion,
    required this.targetVersion,
    required this.requiresShadowGeneration,
    this.buildTargetSchema,
    this.applyInPlace,
    List<BackfillTable> backfillTables = const <BackfillTable>[],
  }) : backfillTables = List<BackfillTable>.unmodifiable(backfillTables) {
    if (targetVersion <= sourceVersion) {
      throw ArgumentError.value(
        targetVersion,
        'targetVersion',
        'Must exceed sourceVersion ($sourceVersion).',
      );
    }
    if (requiresShadowGeneration) {
      if (buildTargetSchema == null) {
        throw ArgumentError(
          'An incompatible plan must provide buildTargetSchema.',
        );
      }
      if (backfillTables.isEmpty) {
        throw ArgumentError(
          'An incompatible plan must list at least one backfill table.',
        );
      }
    } else if (applyInPlace == null) {
      throw ArgumentError('An additive plan must provide applyInPlace.');
    }
  }

  final int sourceVersion;
  final int targetVersion;
  final bool requiresShadowGeneration;

  /// Creates the complete target schema in a fresh shadow store.
  final Future<void> Function(MigrationConnection shadow)? buildTargetSchema;

  /// Applies additive DDL to the live store inside one transaction.
  final Future<void> Function(MigrationConnection source)? applyInPlace;

  /// Tables copied source→shadow, in dependency order (parents first).
  final List<BackfillTable> backfillTables;
}

/// Ordered registry of the migrations Forge supports from every released
/// baseline, not merely N-1 (data-model §5.2).
final class MigrationRegistry {
  MigrationRegistry(List<MigrationPlan> plans)
    : _plans = List<MigrationPlan>.unmodifiable(
        plans.toList()..sort(
          (MigrationPlan a, MigrationPlan b) =>
              a.sourceVersion.compareTo(b.sourceVersion),
        ),
      ) {
    for (int i = 0; i < _plans.length; i += 1) {
      final MigrationPlan plan = _plans[i];
      if (plan.targetVersion != plan.sourceVersion + 1) {
        throw ArgumentError(
          'Plan ${plan.sourceVersion}->${plan.targetVersion} must be a single '
          'version step so the chain is contiguous and auditable.',
        );
      }
      if (i > 0 && plan.sourceVersion != _plans[i - 1].targetVersion) {
        throw ArgumentError(
          'Migration chain has a gap before version ${plan.sourceVersion}.',
        );
      }
    }
  }

  final List<MigrationPlan> _plans;

  /// The contiguous step plans required to move [fromVersion] to [toVersion].
  List<MigrationPlan> path({required int fromVersion, required int toVersion}) {
    if (toVersion == fromVersion) {
      return const <MigrationPlan>[];
    }
    if (toVersion < fromVersion) {
      throw MigrationPathException(
        'Downgrade from $fromVersion to $toVersion is never performed by '
        'mutating a database backward (data-model §5.6).',
      );
    }
    final List<MigrationPlan> chain = <MigrationPlan>[];
    int version = fromVersion;
    while (version < toVersion) {
      final MigrationPlan? step = _plans
          .where((MigrationPlan plan) => plan.sourceVersion == version)
          .cast<MigrationPlan?>()
          .firstWhere(
            (MigrationPlan? plan) => plan != null,
            orElse: () => null,
          );
      if (step == null) {
        throw MigrationPathException(
          'No migration registered from schema version $version; the baseline '
          'is unsupported.',
        );
      }
      chain.add(step);
      version = step.targetVersion;
    }
    return List<MigrationPlan>.unmodifiable(chain);
  }

  /// Whether any step on the path requires shadow-generation activation.
  bool pathRequiresShadow({required int fromVersion, required int toVersion}) =>
      path(
        fromVersion: fromVersion,
        toVersion: toVersion,
      ).any((MigrationPlan plan) => plan.requiresShadowGeneration);
}

/// Raised when no supported migration path exists (unsupported baseline or a
/// downgrade request). It is a Recovery-Mode signal, never a data reset.
final class MigrationPathException implements Exception {
  const MigrationPathException(this.message);

  final String message;

  @override
  String toString() => 'MigrationPathException($message)';
}
