import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/features/insights/domain/aggregate_cache_store.dart';
import 'package:forge/features/insights/infrastructure/drift_aggregate_cache_store.dart';

import '../schema/schema_test_database.dart';

/// The reproducible derived-aggregate cache over the real `aggregate_cache`
/// table (R-INSIGHT-004): read/write round-trip and watermark invalidation.
void main() {
  late ForgeSchemaDatabase db;
  late DriftAggregateCacheStore store;
  late String profileId;

  setUp(() async {
    db = openSchemaDatabase();
    profileId = await insertProfile(db);
    store = DriftAggregateCacheStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  CachedAggregate entry({
    required String cacheKey,
    required int watermark,
    String value = '{"task_num":1}',
  }) => CachedAggregate(
    profileId: profileId,
    cacheKey: cacheKey,
    metric: 'period_insight',
    rangeHash: 'weekly:2024-W23',
    filterHash: 'area-1',
    policyVersion: 1,
    sourceCommitSeq: watermark,
    value: value,
    updatedAtUtc: 10,
  );

  Future<int> rowCount() async {
    final int count = await db
        .customSelect('SELECT COUNT(*) AS c FROM aggregate_cache')
        .map((row) => row.read<int>('c'))
        .getSingle();
    return count;
  }

  test('[TEST-DB-INSIGHT-CACHE-ROUNDTRIP][V1][TASK-10.4][R-INSIGHT-004] '
      'a written aggregate is read back exactly', () async {
    await store.write(
      entry(
        cacheKey: 'period_insight|weekly:2024-W23|area-1|v1|w100',
        watermark: 100,
      ),
    );

    final CachedAggregate? read = await store.read(
      profileId,
      cacheKey: 'period_insight|weekly:2024-W23|area-1|v1|w100',
    );
    expect(read, isNotNull);
    expect(read!.sourceCommitSeq, 100);
    expect(read.value, '{"task_num":1}');
    expect(read.policyVersion, 1);
  });

  test('[TEST-DB-INSIGHT-CACHE-MISS][V1][TASK-10.4][R-INSIGHT-004] '
      'a missing key reads as null', () async {
    expect(await store.read(profileId, cacheKey: 'absent'), isNull);
  });

  test(
    '[TEST-DB-INSIGHT-CACHE-INVALIDATION][V1][TASK-10.4][R-INSIGHT-004] '
    'a new watermark supersedes the prior entry, leaving one live row',
    () async {
      await store.write(
        entry(
          cacheKey: 'period_insight|weekly:2024-W23|area-1|v1|w100',
          watermark: 100,
          value: '{"task_num":2}',
        ),
      );
      expect(await rowCount(), 1);

      // A watermark advance writes a new key and purges the superseded one.
      await store.write(
        entry(
          cacheKey: 'period_insight|weekly:2024-W23|area-1|v1|w250',
          watermark: 250,
          value: '{"task_num":4}',
        ),
      );

      expect(await rowCount(), 1);
      expect(
        await store.read(
          profileId,
          cacheKey: 'period_insight|weekly:2024-W23|area-1|v1|w100',
        ),
        isNull,
      );
      final CachedAggregate? live = await store.read(
        profileId,
        cacheKey: 'period_insight|weekly:2024-W23|area-1|v1|w250',
      );
      expect(live!.sourceCommitSeq, 250);
      expect(live.value, '{"task_num":4}');
    },
  );

  test('[TEST-DB-INSIGHT-CACHE-INDEPENDENT][V1][TASK-10.4][R-INSIGHT-004] '
      'a different window keeps its own live entry', () async {
    await store.write(
      entry(
        cacheKey: 'period_insight|weekly:2024-W23|area-1|v1|w100',
        watermark: 100,
      ),
    );
    // A different filter/window is a distinct rangeHash/filterHash, so it is
    // not purged by the first window's write.
    await store.write(
      CachedAggregate(
        profileId: profileId,
        cacheKey: 'period_insight|monthly:2024-06|area-1|v1|w100',
        metric: 'period_insight',
        rangeHash: 'monthly:2024-06',
        filterHash: 'area-1',
        policyVersion: 1,
        sourceCommitSeq: 100,
        value: '{"task_num":9}',
        updatedAtUtc: 10,
      ),
    );
    expect(await rowCount(), 2);
  });
}
