/// Property 6: No resurrection or opaque derivation.
///
/// Two invariants proven across randomized scenarios against the real domain
/// code (no mocks):
///
/// 1. **No resurrection (`R-GEN-003`).** A tombstoned entity can never be
///    resurrected — not by human-readable import (task 10.6's collision-remap
///    must remap *around* a tombstone, never overwrite or revive it), and not
///    by a sync delete-versus-update apply (task 9.3's tombstone/update
///    preservation keeps the tombstone the visible state and files the
///    concurrent update into a durable artifact instead of resurrecting it).
///    Across random sequences of delete + later operations (import, re-add) a
///    tombstoned id stays dead: its content never reappears under the original
///    id.
///
/// 2. **Reproducible aggregates / no opaque derivation (`R-INSIGHT-004`).**
///    Every displayed aggregate (Daily Summary + weekly/monthly
///    `PeriodInsight`) is reproducible from its source under its versioned
///    metric policy + source watermark: recomputing at the same watermark — hot
///    cache or cold recompute — yields the identical value, and every figure
///    exposes its numerator/denominator or its underlying seconds, never an
///    opaque score.
///
/// **Property 6: No resurrection or opaque derivation**
/// **Validates: Requirements R-GEN-003, R-INSIGHT-004**
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/time_span.dart';
import 'package:forge/features/backup/domain/human_readable_export.dart';
import 'package:forge/features/backup/domain/import_plan.dart';
import 'package:forge/features/focus/application/focus_duration_contract.dart';
import 'package:forge/features/insights/application/combined_time_metrics_service.dart';
import 'package:forge/features/insights/application/daily_summary_service.dart';
import 'package:forge/features/insights/application/period_insights_service.dart';
import 'package:forge/features/insights/domain/aggregate_cache_store.dart';
import 'package:forge/features/insights/domain/daily_summary.dart';
import 'package:forge/features/insights/domain/insight_period.dart';
import 'package:forge/features/insights/domain/metric_policy.dart';
import 'package:forge/features/insights/domain/period_insight.dart';
import 'package:forge/features/learning/application/learning_duration_contract.dart';
import 'package:forge/features/planner/application/planner_summary_contract.dart';
import 'package:forge/features/sync/domain/conflict/conflict_artifact.dart';
import 'package:forge/features/sync/domain/conflict/entity_conflict_policy.dart';

import '../helpers/helpers.dart';

// ---------------------------------------------------------------------------
// Evidence metadata
// ---------------------------------------------------------------------------

EvidenceMetadata _resurrectionEvidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-PROP6-NO-RESURRECTION-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('10.7'),
  requirements: <RequirementId>[RequirementId('R-GEN-003')],
);

EvidenceMetadata _reproducibleEvidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-PROP6-REPRODUCIBLE-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('10.7'),
  requirements: <RequirementId>[RequirementId('R-INSIGHT-004')],
);

EvidenceMetadata _property6Evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-PROP6-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('10.7'),
  requirements: <RequirementId>[
    RequirementId('R-GEN-003'),
    RequirementId('R-INSIGHT-004'),
  ],
);

// ---------------------------------------------------------------------------
// Fakes wiring the real application services (no mocks; production logic runs)
// ---------------------------------------------------------------------------

final class _FakePlanner implements PlannerSummaryContract {
  _FakePlanner(this.closesByDay);

  final Map<String, PlannerDailyCloseSnapshot> closesByDay;

  @override
  Future<PlannerDailyCloseSnapshot?> dailyClose(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required String dayKey,
  }) async => closesByDay[dayKey];

  @override
  Future<List<PlannerDailyCloseSnapshot>> dailyCloses(
    ProfileId profileId, {
    required LifeAreaId lifeAreaId,
    required List<String> dayKeys,
  }) async => <PlannerDailyCloseSnapshot>[
    for (final String key in dayKeys)
      if (closesByDay[key] != null) closesByDay[key]!,
  ];
}

final class _FakeFocus implements FocusDurationContract {
  _FakeFocus(this.spans);
  final List<TimeSpan> spans;
  @override
  Future<List<TimeSpan>> focusWorkSpans(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
  }) async => spans;
}

final class _FakeStudy implements StudyDurationContract {
  _FakeStudy(this.spans);
  final List<TimeSpan> spans;
  @override
  Future<List<TimeSpan>> studyIntervals(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
    LearningResourceId? resourceId,
  }) async => spans;
}

/// In-memory aggregate cache mirroring the durable store's supersede-then-upsert
/// invalidation so a changed watermark deterministically recomputes.
final class _FakeCache implements AggregateCacheStore {
  final Map<String, CachedAggregate> _rows = <String, CachedAggregate>{};
  int reads = 0;
  int writes = 0;

  String _pk(String profileId, String cacheKey) => '$profileId::$cacheKey';

  @override
  Future<CachedAggregate?> read(
    String profileId, {
    required String cacheKey,
  }) async {
    reads += 1;
    return _rows[_pk(profileId, cacheKey)];
  }

  @override
  Future<void> write(CachedAggregate entry) async {
    writes += 1;
    _rows.removeWhere(
      (String key, CachedAggregate row) =>
          row.profileId == entry.profileId &&
          row.metric == entry.metric &&
          row.rangeHash == entry.rangeHash &&
          row.filterHash == entry.filterHash &&
          row.policyVersion == entry.policyVersion &&
          row.cacheKey != entry.cacheKey,
    );
    _rows[_pk(entry.profileId, entry.cacheKey)] = entry;
  }
}

/// Deterministic minter for remapped IDs. Uses a `gen-` prefix that can never
/// collide with the generator's `t`/`a` document IDs.
final class _SeqMinter implements ImportIdMinter {
  int _next = 0;
  @override
  String mint() => 'gen-${_next++}';
}

void main() {
  const int s = IntervalUnion.microsPerSecond;
  final ProfileId profile = ProfileId('profile-1');
  final LifeAreaId area = LifeAreaId('area-1');

  // =========================================================================
  // Invariant 1 — No resurrection (R-GEN-003)
  // =========================================================================

  group('[TEST-PROP6-NO-RESURRECTION-IMPORT][V1][TASK-10.7][R-GEN-003] '
      'tombstones survive random delete + import + re-add sequences', () {
    testWithEvidence(
      _resurrectionEvidence('IMPORT'),
      'a tombstoned id never has content written under it and stays dead '
      'across randomized operation sequences',
      () {
        const ImportPlanner planner = ImportPlanner();
        const String table = 'tasks';
        const List<String> columns = <String>[
          'id',
          'life_area_id',
          'title',
          'deleted_at_utc',
        ];

        for (int seed = 0; seed < 400; seed += 1) {
          final Random rng = Random(seed);

          // The local generation: id -> (content, isTombstone).
          final Map<String, ExistingRow> local = <String, ExistingRow>{};
          // Every id that has ever been tombstoned, with the tombstone
          // content captured at deletion time.
          final Map<String, Map<String, String?>> deadContent =
              <String, Map<String, String?>>{};
          final _SeqMinter minter = _SeqMinter();

          // Seed a few live rows.
          final int seedRows = 1 + rng.nextInt(4);
          for (int i = 0; i < seedRows; i += 1) {
            local['t$i'] = ExistingRow(
              values: <String, String?>{
                'id': 't$i',
                'life_area_id': 'a1',
                'title': 'seed-$i',
                'deleted_at_utc': null,
              },
              isTombstone: false,
            );
          }
          int nextRowId = seedRows;

          final int steps = 3 + rng.nextInt(8);
          for (int step = 0; step < steps; step += 1) {
            final int choice = rng.nextInt(3);
            if (choice == 0) {
              // delete: soft-delete a random live row into a tombstone.
              final List<String> live = local.entries
                  .where(
                    (MapEntry<String, ExistingRow> e) => !e.value.isTombstone,
                  )
                  .map((MapEntry<String, ExistingRow> e) => e.key)
                  .toList();
              if (live.isEmpty) {
                continue;
              }
              final String victim = live[rng.nextInt(live.length)];
              final Map<String, String?> tombstoneValues = <String, String?>{
                'id': victim,
                'life_area_id': null,
                'title': null,
                'deleted_at_utc': '${1000 + step}',
              };
              local[victim] = ExistingRow(
                values: tombstoneValues,
                isTombstone: true,
              );
              deadContent[victim] = tombstoneValues;
            } else {
              // import / re-add: build a document that may reuse dead ids,
              // live ids, and fresh ids, then plan + commit it.
              final List<Map<String, String?>> incoming =
                  <Map<String, String?>>[];
              final List<String> candidateIds = <String>[
                ...local.keys,
                't${nextRowId++}',
                if (deadContent.isNotEmpty)
                  deadContent.keys.elementAt(rng.nextInt(deadContent.length)),
              ];
              final int rowCount = 1 + rng.nextInt(candidateIds.length);
              final Set<String> usedIds = <String>{};
              for (int r = 0; r < rowCount; r += 1) {
                final String id =
                    candidateIds[rng.nextInt(candidateIds.length)];
                if (!usedIds.add(id)) {
                  continue;
                }
                incoming.add(<String, String?>{
                  'id': id,
                  'life_area_id': 'a1',
                  // Deliberately fresh content so a resurrection would be
                  // observable as "reappeared under the original id".
                  'title': 'import-$seed-$step-$r',
                  'deleted_at_utc': null,
                });
              }

              final ExportDocument document = ExportDocument(
                createdAtUtcMicros: 1,
                profileId: 'p',
                tables: <ExportTable>[
                  ExportTable(name: table, columns: columns, rows: incoming),
                ],
              );

              final ImportPlan plan = planner.plan(
                document: document,
                existing: <String, Map<String, ExistingRow>>{
                  table: Map<String, ExistingRow>.from(local),
                },
                minter: minter,
              );

              // Index incoming content by original id to commit writes.
              final Map<String, Map<String, String?>> incomingById =
                  <String, Map<String, String?>>{
                    for (final Map<String, String?> row in incoming)
                      row['id']!: row,
                  };

              for (final ImportRowPlan rowPlan in plan.rows) {
                // A row colliding with a local tombstone must be remapped so
                // the deletion can never resurrect.
                final ExistingRow? existing = local[rowPlan.originalId];
                if (existing != null && existing.isTombstone) {
                  expect(
                    rowPlan.disposition,
                    ImportDisposition.remapTombstoneBlocked,
                    reason:
                        'seed=$seed step=$step id=${rowPlan.originalId} '
                        'must remap around the tombstone',
                  );
                  expect(
                    rowPlan.finalId,
                    isNot(rowPlan.originalId),
                    reason: 'remap must mint a fresh id',
                  );
                }

                if (!rowPlan.writes) {
                  continue;
                }
                // A write must never land on an existing live *or* tombstoned
                // id: fresh ids are minted for every collision.
                final ExistingRow? clash = local[rowPlan.finalId];
                expect(
                  clash == null,
                  isTrue,
                  reason:
                      'seed=$seed write finalId=${rowPlan.finalId} '
                      'overwrote an existing row',
                );
                // Commit the write under its final id.
                local[rowPlan.finalId] = ExistingRow(
                  values: incomingById[rowPlan.originalId]!,
                  isTombstone: false,
                );
              }
            }

            // Invariant after every step: every dead id is still a tombstone
            // and its content never reappeared under the original id.
            for (final MapEntry<String, Map<String, String?>> dead
                in deadContent.entries) {
              final ExistingRow? row = local[dead.key];
              expect(
                row,
                isNotNull,
                reason: 'seed=$seed dead id ${dead.key} vanished',
              );
              expect(
                row!.isTombstone,
                isTrue,
                reason:
                    'seed=$seed dead id ${dead.key} was resurrected to live',
              );
              expect(
                row.values['deleted_at_utc'],
                isNotNull,
                reason:
                    'seed=$seed dead id ${dead.key} lost its tombstone marker',
              );
              expect(
                row.values['title'],
                isNull,
                reason: 'seed=$seed dead id ${dead.key} regained live content',
              );
            }
          }
        }
      },
    );
  });

  group(
    '[TEST-PROP6-NO-RESURRECTION-SYNC][V1][TASK-10.7][R-GEN-003] '
    'sync delete-versus-update keeps the tombstone and preserves the update',
    () {
      testWithEvidence(
        _resurrectionEvidence('SYNC'),
        'a concurrent update never resurrects a tombstone; it is preserved in a '
        'durable artifact instead',
        () {
          const EntityConflictPolicy policy = EntityConflictPolicy();
          const List<String> fields = <String>['title', 'notes', 'priority'];

          for (int seed = 0; seed < 400; seed += 1) {
            final Random rng = Random(seed);

            final Map<String, Object?> base = <String, Object?>{
              for (final String f in fields) f: 'base-$f',
            };
            // A random concurrent update touching a random subset of fields.
            final List<String> changed = fields
                .where((String _) => rng.nextBool())
                .toList();
            final Map<String, Object?> values = <String, Object?>{
              for (final String f in changed) f: 'edit-$seed-$f',
            };
            final EntityEdit update = EntityEdit(
              changedFields: changed,
              values: values,
            );

            final TombstoneMergeResult result = policy
                .resolveDeleteVersusUpdate(
                  entityType: 'task',
                  entityId: 'e-$seed',
                  survivingUpdate: update,
                  baseValues: base,
                  createdAtUtc: 5000,
                  artifactId: changed.isEmpty ? null : 'artifact-$seed',
                );

            // The tombstone always wins the visible state — no resurrection.
            expect(
              result.tombstoneWins,
              isTrue,
              reason: 'seed=$seed tombstone must win visible state',
            );

            if (changed.isEmpty) {
              // Delete vs delete: nothing meaningful to preserve.
              expect(result.artifact, isNull);
            } else {
              // The update is preserved out-of-band, never merged into the
              // (deleted) visible entity.
              final ConflictArtifact? artifact = result.artifact;
              expect(artifact, isNotNull, reason: 'seed=$seed');
              expect(
                artifact!.policy,
                ConflictPolicyKind.tombstoneUpdatePreserved,
              );
              expect(artifact.fields.toSet(), changed.toSet());
              final Map<String, Object?>? preserved = artifact.localSnapshot;
              expect(preserved, isNotNull, reason: 'seed=$seed');
              for (final String f in changed) {
                expect(
                  preserved![f],
                  values[f],
                  reason: 'seed=$seed preserved value for $f',
                );
              }
            }
          }
        },
      );
    },
  );

  // =========================================================================
  // Invariant 2 — Reproducible aggregates / no opaque derivation (R-INSIGHT-004)
  // =========================================================================

  PlannerDailyCloseSnapshot randomClose(Random rng, String periodId) {
    final int eligible = rng.nextInt(6);
    final int completed = eligible == 0 ? 0 : rng.nextInt(eligible + 1);
    final int missed = eligible - completed;
    final int carried = missed == 0 ? 0 : rng.nextInt(missed + 1);
    final int habitCount = rng.nextInt(5);
    const List<String> statuses = <String>[
      'completed',
      'missed',
      'skipped',
      'paused',
      'open',
    ];
    final List<PlannerHabitCloseOutcome> habits = <PlannerHabitCloseOutcome>[
      for (int i = 0; i < habitCount; i += 1)
        PlannerHabitCloseOutcome(
          occurrenceId: '$periodId-h$i',
          statusWire: statuses[rng.nextInt(statuses.length)],
        ),
    ];
    return PlannerDailyCloseSnapshot(
      periodId: periodId,
      closedAtUtc: 2000,
      boundaryUtc: 1500,
      metricPolicyNumber: 1,
      sourceWatermarkCommitSeq: 1 + rng.nextInt(500),
      tasks: PlannerTaskCloseTally(
        eligibleCount: eligible,
        completedCount: completed,
        missedCount: missed,
        carriedCount: carried,
        eligibleRootHash: 'e-$periodId',
        completedRootHash: 'c-$periodId',
      ),
      habits: habits,
      adjustmentCount: rng.nextInt(4),
    );
  }

  List<TimeSpan> randomSpans(Random rng, int count) => <TimeSpan>[
    for (int i = 0; i < count; i += 1)
      () {
        final int start = rng.nextInt(2000);
        return TimeSpan(
          startUtc: start * s,
          endUtc: (start + rng.nextInt(240)) * s,
        );
      }(),
  ];

  InsightPeriod randomPeriod(Random rng) {
    final LocalDate anchor = LocalDate(
      2024,
      1 + rng.nextInt(12),
      1 + rng.nextInt(28),
    );
    return rng.nextBool()
        ? InsightPeriod.weekly(
            anchor,
            timezoneId: 'UTC',
            rangeStartUtc: 0,
            rangeEndUtc: 100000 * s,
          )
        : InsightPeriod.monthly(
            anchor,
            timezoneId: 'UTC',
            rangeStartUtc: 0,
            rangeEndUtc: 100000 * s,
          );
  }

  PeriodInsightsService periodService(
    Map<String, PlannerDailyCloseSnapshot> closes,
    List<TimeSpan> focus,
    List<TimeSpan> study,
    AggregateCacheStore cache,
  ) => PeriodInsightsService(
    plannerSummary: _FakePlanner(closes),
    combinedTime: CombinedTimeMetricsService(
      focusDuration: _FakeFocus(focus),
      studyDuration: _FakeStudy(study),
    ),
    cache: cache,
    clock: FakeClock(initialUtc: DateTime.utc(2024, 6, 3, 12)),
  );

  void expectSamePeriodInsight(PeriodInsight a, PeriodInsight b, String why) {
    expect(a.taskCompletion, b.taskCompletion, reason: '$why taskCompletion');
    expect(
      a.habitConsistency,
      b.habitConsistency,
      reason: '$why habitConsistency',
    );
    expect(a.missedCount, b.missedCount, reason: '$why missed');
    expect(a.carriedCount, b.carriedCount, reason: '$why carried');
    expect(
      a.combinedFocusStudySeconds,
      b.combinedFocusStudySeconds,
      reason: '$why combined',
    );
    expect(
      a.focusStudyOverlapSeconds,
      b.focusStudyOverlapSeconds,
      reason: '$why overlap',
    );
    expect(
      a.sourceWatermarkCommitSeq,
      b.sourceWatermarkCommitSeq,
      reason: '$why watermark',
    );
    expect(
      a.metricPolicyNumber,
      b.metricPolicyNumber,
      reason: '$why policyNumber',
    );
    expect(a.closedDayCount, b.closedDayCount, reason: '$why closedDays');
  }

  group('[TEST-PROP6-REPRODUCIBLE-PERIOD][V1][TASK-10.7][R-INSIGHT-004] '
      'weekly/monthly Insights reproduce identically at the same watermark', () {
    testWithEvidence(
      _reproducibleEvidence('PERIOD'),
      'a hot-cache read and an independent cold recompute at the same '
      'watermark yield the identical value',
      () async {
        for (int seed = 0; seed < 250; seed += 1) {
          final Random rng = Random(seed);
          final InsightPeriod period = randomPeriod(rng);

          final Map<String, PlannerDailyCloseSnapshot> closes =
              <String, PlannerDailyCloseSnapshot>{};
          for (final String dayKey in period.dayKeys) {
            if (rng.nextBool()) {
              closes[dayKey] = randomClose(rng, dayKey);
            }
          }
          final List<TimeSpan> focus = randomSpans(rng, rng.nextInt(4));
          final List<TimeSpan> study = randomSpans(rng, rng.nextInt(4));

          // Service A: compute, then re-read (hot cache reproduction).
          final _FakeCache cacheA = _FakeCache();
          final PeriodInsightsService serviceA = periodService(
            closes,
            focus,
            study,
            cacheA,
          );
          final PeriodInsight first = await serviceA.insight(
            profile,
            period,
            lifeAreaId: area,
          );
          final PeriodInsight hot = await serviceA.insight(
            profile,
            period,
            lifeAreaId: area,
          );
          expectSamePeriodInsight(hot, first, 'seed=$seed hot-cache');

          // Service B: a fresh cold cache recomputes from source at the same
          // watermark and must match — the aggregate is derived, never opaque.
          final PeriodInsight cold = await periodService(
            closes,
            focus,
            study,
            _FakeCache(),
          ).insight(profile, period, lifeAreaId: area);
          expectSamePeriodInsight(cold, first, 'seed=$seed cold-recompute');

          // If any day was closed, the hot read must have been served from
          // the cache (no second write).
          if (closes.isNotEmpty) {
            expect(
              cacheA.writes,
              1,
              reason: 'seed=$seed same watermark must not rewrite the cache',
            );
          }

          // No opaque derivation: every displayed figure is reconstructible
          // from its numerator/denominator or its underlying seconds.
          final MetricRatio task = first.taskCompletion;
          if (task.hasData) {
            expect(
              task.ratio,
              closeTo(task.numerator / task.denominator, 1e-12),
              reason: 'seed=$seed task ratio must equal num/den',
            );
          } else {
            expect(task.ratio, isNull, reason: 'seed=$seed no-data not 0%');
          }
          final MetricRatio habit = first.habitConsistency;
          expect(habit.numerator, lessThanOrEqualTo(habit.denominator));
          expect(
            first.combinedFocusStudySeconds,
            greaterThanOrEqualTo(0),
            reason: 'seed=$seed combined seconds are concrete, not a score',
          );
          expect(first.metricPolicyVersion, 'metric-policy-v1');
        }
      },
    );
  });

  group(
    '[TEST-PROP6-REPRODUCIBLE-INVALIDATE][V1][TASK-10.7][R-INSIGHT-004] '
    'a changed source watermark deterministically invalidates and recomputes',
    () {
      testWithEvidence(
        _reproducibleEvidence('INVALIDATE'),
        'advancing the source watermark recomputes from source and reflects the '
        'new sealed counts, keeping one live cache entry',
        () async {
          for (int seed = 0; seed < 200; seed += 1) {
            final Random rng = Random(seed);
            final InsightPeriod period = InsightPeriod.weekly(
              LocalDate(2024, 6, 3),
              timezoneId: 'UTC',
              rangeStartUtc: 0,
              rangeEndUtc: 100000 * s,
            );
            final String dayKey = period.dayKeys.first;
            final int eligible = 2 + rng.nextInt(4);
            final Map<String, PlannerDailyCloseSnapshot> closes =
                <String, PlannerDailyCloseSnapshot>{
                  dayKey: PlannerDailyCloseSnapshot(
                    periodId: 'p',
                    closedAtUtc: 2000,
                    boundaryUtc: 1500,
                    metricPolicyNumber: 1,
                    sourceWatermarkCommitSeq: 100,
                    tasks: PlannerTaskCloseTally(
                      eligibleCount: eligible,
                      completedCount: 1,
                      missedCount: eligible - 1,
                      carriedCount: 0,
                      eligibleRootHash: 'e',
                      completedRootHash: 'c',
                    ),
                    habits: const <PlannerHabitCloseOutcome>[],
                    adjustmentCount: 0,
                  ),
                };
            final _FakeCache cache = _FakeCache();
            final PeriodInsightsService service = periodService(
              closes,
              const <TimeSpan>[],
              const <TimeSpan>[],
              cache,
            );

            final PeriodInsight before = await service.insight(
              profile,
              period,
              lifeAreaId: area,
            );
            expect(before.taskCompletion.numerator, 1);
            expect(cache.writes, 1);

            // A source correction advances the watermark and the sealed counts.
            closes[dayKey] = PlannerDailyCloseSnapshot(
              periodId: 'p',
              closedAtUtc: 2000,
              boundaryUtc: 1500,
              metricPolicyNumber: 1,
              sourceWatermarkCommitSeq: 250,
              tasks: PlannerTaskCloseTally(
                eligibleCount: eligible,
                completedCount: eligible,
                missedCount: 0,
                carriedCount: 0,
                eligibleRootHash: 'e',
                completedRootHash: 'c',
              ),
              habits: const <PlannerHabitCloseOutcome>[],
              adjustmentCount: 0,
            );

            final PeriodInsight after = await service.insight(
              profile,
              period,
              lifeAreaId: area,
            );
            expect(
              after.taskCompletion.numerator,
              eligible,
              reason: 'seed=$seed recompute must reflect the new source',
            );
            expect(after.sourceWatermarkCommitSeq, 250);
            expect(
              cache.writes,
              2,
              reason: 'seed=$seed changed watermark must recompute',
            );
          }
        },
      );
    },
  );

  DailySummaryService dailyService(
    PlannerDailyCloseSnapshot? snap,
    List<TimeSpan> focus,
    List<TimeSpan> study,
  ) => DailySummaryService(
    plannerSummary: _FakePlanner(
      snap == null
          ? <String, PlannerDailyCloseSnapshot>{}
          : <String, PlannerDailyCloseSnapshot>{'2024-06-01': snap},
    ),
    combinedTime: CombinedTimeMetricsService(
      focusDuration: _FakeFocus(focus),
      studyDuration: _FakeStudy(study),
    ),
  );

  group(
    '[TEST-PROP6-REPRODUCIBLE-DAILY][V1][TASK-10.7][R-INSIGHT-004] '
    'the Daily Summary reproduces identically and exposes concrete figures',
    () {
      testWithEvidence(
        _reproducibleEvidence('DAILY'),
        'recomputing the Daily Summary at the same watermark yields the '
        'identical value with no opaque score',
        () async {
          for (int seed = 0; seed < 250; seed += 1) {
            final Random rng = Random(seed);
            final PlannerDailyCloseSnapshot snap = randomClose(rng, 'day');
            final List<TimeSpan> focus = randomSpans(rng, rng.nextInt(4));
            final List<TimeSpan> study = randomSpans(rng, rng.nextInt(4));

            Future<DailySummary?> compute() =>
                dailyService(snap, focus, study).summarize(
                  profile,
                  lifeAreaId: area,
                  dayKey: '2024-06-01',
                  dayStartUtc: 0,
                  dayEndUtc: 100000 * s,
                );

            final DailySummary a = (await compute())!;
            final DailySummary b = (await compute())!;

            expect(a.taskCompletion, b.taskCompletion, reason: 'seed=$seed');
            expect(a.habits.completion, b.habits.completion);
            expect(a.combinedFocusStudySeconds, b.combinedFocusStudySeconds);
            expect(a.focusStudyOverlapSeconds, b.focusStudyOverlapSeconds);
            expect(a.sourceWatermarkCommitSeq, snap.sourceWatermarkCommitSeq);
            expect(a.metricPolicyVersion, 'metric-policy-v1');

            // Every figure is concrete: a ratio equals num/den (or "no data"),
            // and combined time is whole seconds — never an opaque score.
            if (a.taskCompletion.hasData) {
              expect(
                a.taskCompletion.ratio,
                closeTo(
                  a.taskCompletion.numerator / a.taskCompletion.denominator,
                  1e-12,
                ),
              );
            } else {
              expect(a.taskCompletion.ratio, isNull);
            }
            expect(
              a.combinedFocusStudySeconds,
              IntervalUnion.unionSeconds(<TimeSpan>[...focus, ...study]),
              reason: 'seed=$seed combined time is the interval union',
            );
          }
        },
      );
    },
  );

  // A small combined anchor tying both invariants together under the shared
  // Property 6 tag, so the trace carries the exact `R-GEN-003,R-INSIGHT-004`
  // edge the task requires.
  group('[TEST-PROP6-JOINT][V1][TASK-10.7][R-GEN-003,R-INSIGHT-004] '
      'Property 6 joint anchor', () {
    testWithEvidence(
      _property6Evidence('JOINT'),
      'a tombstone stays dead through import while its Insight remains '
      'reproducible from source',
      () async {
        const ImportPlanner planner = ImportPlanner();
        // A tombstoned task cannot be revived by an import that reuses its id.
        final ImportPlan plan = planner.plan(
          document: ExportDocument(
            createdAtUtcMicros: 1,
            profileId: 'p',
            tables: <ExportTable>[
              ExportTable(
                name: 'tasks',
                columns: const <String>[
                  'id',
                  'life_area_id',
                  'title',
                  'deleted_at_utc',
                ],
                rows: const <Map<String, String?>>[
                  <String, String?>{
                    'id': 'dead-1',
                    'life_area_id': 'a1',
                    'title': 'zombie',
                    'deleted_at_utc': null,
                  },
                ],
              ),
            ],
          ),
          existing: <String, Map<String, ExistingRow>>{
            'tasks': <String, ExistingRow>{
              'dead-1': const ExistingRow(
                values: <String, String?>{'id': 'dead-1'},
                isTombstone: true,
              ),
            },
          },
          minter: _SeqMinter(),
        );
        expect(
          plan.rows.single.disposition,
          ImportDisposition.remapTombstoneBlocked,
        );
        expect(plan.rows.single.finalId, isNot('dead-1'));

        // The same-watermark Insight reproduces identically.
        final Map<String, PlannerDailyCloseSnapshot> closes =
            <String, PlannerDailyCloseSnapshot>{
              '2024-06-03': randomClose(Random(7), 'p1'),
            };
        final InsightPeriod period = InsightPeriod.weekly(
          LocalDate(2024, 6, 3),
          timezoneId: 'UTC',
          rangeStartUtc: 0,
          rangeEndUtc: 100000 * s,
        );
        final _FakeCache cache = _FakeCache();
        final PeriodInsightsService service = periodService(
          closes,
          const <TimeSpan>[],
          const <TimeSpan>[],
          cache,
        );
        final PeriodInsight a = await service.insight(
          profile,
          period,
          lifeAreaId: area,
        );
        final PeriodInsight b = await service.insight(
          profile,
          period,
          lifeAreaId: area,
        );
        expectSamePeriodInsight(b, a, 'joint');
        expect(cache.writes, 1);
      },
    );
  });
}
