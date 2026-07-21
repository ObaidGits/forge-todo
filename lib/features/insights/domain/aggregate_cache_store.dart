/// A durable local cache of a reproducible derived aggregate (R-INSIGHT-004).
///
/// Derived aggregates MAY be cached but SHALL remain reproducible from source
/// under a `metric_policy_version` and a `source_commit_seq`. This value mirrors
/// the `aggregate_cache` row: the cache identity ([cacheKey]) folds the metric,
/// window, filter, policy version, and source watermark together, so a cached
/// value is only ever returned for the exact `(period, policy-version,
/// watermark)` it was computed for. When the source watermark advances the key
/// changes, the old value is superseded, and the aggregate is recomputed
/// deterministically. Caches are local-only and never synced (data-model §6).
final class CachedAggregate {
  const CachedAggregate({
    required this.profileId,
    required this.cacheKey,
    required this.metric,
    required this.rangeHash,
    required this.filterHash,
    required this.policyVersion,
    required this.sourceCommitSeq,
    required this.value,
    required this.updatedAtUtc,
  });

  final String profileId;
  final String cacheKey;
  final String metric;
  final String rangeHash;
  final String filterHash;
  final int policyVersion;
  final int sourceCommitSeq;

  /// The serialized aggregate value (JSON).
  final String value;
  final int updatedAtUtc;
}

/// The port the insights feature uses to read and persist reproducible derived
/// aggregates. The implementation lives in infrastructure over the
/// `aggregate_cache` table (design.md §4/§14).
abstract interface class AggregateCacheStore {
  /// The cached aggregate stored under [cacheKey], or null on a miss.
  Future<CachedAggregate?> read(String profileId, {required String cacheKey});

  /// Upserts [entry] and, for correct invalidation, removes any superseded
  /// entry that shares the same metric/window/filter/policy but a different
  /// source watermark, so exactly one live entry per `(period, policy)` remains.
  Future<void> write(CachedAggregate entry);
}
