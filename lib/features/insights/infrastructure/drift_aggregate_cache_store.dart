import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/features/insights/domain/aggregate_cache_store.dart';

/// Persists reproducible derived aggregates in the `aggregate_cache` table
/// (R-INSIGHT-004, data-model §3).
///
/// The cache is a local-only, area-free operational projection that is never
/// synced (data-model §6): it stores a value keyed by `(profile, cache_key)`
/// where the key already folds the window, filter, policy version, and source
/// watermark together. A [write] runs one transaction that first purges any
/// superseded entry for the same window/filter/policy under a *different* source
/// watermark, then upserts the current one, so exactly one live entry per
/// `(window, policy)` remains and a watermark advance deterministically
/// invalidates the stale value.
final class DriftAggregateCacheStore implements AggregateCacheStore {
  DriftAggregateCacheStore(this._db);

  final ForgeSchemaDatabase _db;

  @override
  Future<CachedAggregate?> read(
    String profileId, {
    required String cacheKey,
  }) async {
    final AggregateCacheRow? row =
        await (_db.select(_db.aggregateCache)..where(
              (AggregateCache c) =>
                  c.profileId.equals(profileId) & c.cacheKey.equals(cacheKey),
            ))
            .getSingleOrNull();
    if (row == null) {
      return null;
    }
    return CachedAggregate(
      profileId: row.profileId,
      cacheKey: row.cacheKey,
      metric: row.metric,
      rangeHash: row.rangeHash,
      filterHash: row.filterHash,
      policyVersion: row.policyVersion,
      sourceCommitSeq: row.sourceCommitSeq,
      value: row.value,
      updatedAtUtc: row.updatedAtUtc,
    );
  }

  @override
  Future<void> write(CachedAggregate entry) async {
    await _db.transaction(() async {
      // Correct invalidation: drop any prior entry for the same window/filter/
      // policy computed under a different watermark before writing the current
      // one, so a superseded aggregate never lingers.
      await (_db.delete(_db.aggregateCache)..where(
            (AggregateCache c) =>
                c.profileId.equals(entry.profileId) &
                c.metric.equals(entry.metric) &
                c.rangeHash.equals(entry.rangeHash) &
                c.filterHash.equals(entry.filterHash) &
                c.policyVersion.equals(entry.policyVersion) &
                c.cacheKey.equals(entry.cacheKey).not(),
          ))
          .go();
      await _db
          .into(_db.aggregateCache)
          .insertOnConflictUpdate(
            AggregateCacheCompanion.insert(
              profileId: entry.profileId,
              cacheKey: entry.cacheKey,
              metric: entry.metric,
              rangeHash: entry.rangeHash,
              filterHash: entry.filterHash,
              policyVersion: entry.policyVersion,
              sourceCommitSeq: entry.sourceCommitSeq,
              value: entry.value,
              updatedAtUtc: entry.updatedAtUtc,
            ),
          );
    });
  }
}
