import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/planner/domain/planning_close.dart';
import 'package:forge/features/planner/domain/planning_entry.dart';
import 'package:forge/features/planner/domain/planning_period.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';
import 'package:forge/features/planner/infrastructure/planner_mapper.dart';

/// Transaction-scoped write access to the planner tables (R-PLAN-001..004).
///
/// Created per transaction by the unit of work and resolved from the session
/// repository set inside a command body (design.md §5). The shared [scope]
/// rejects any use after the owning transaction completes. Factual close events
/// and close items/adjustments are immutable once written; only
/// `planning_periods` rows are updated in place.
final class PlannerWriteRepository {
  PlannerWriteRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;

  // ---- planning_periods ---------------------------------------------------

  Future<PlanningPeriod?> findPeriodByKey(
    String profileId, {
    required String lifeAreaId,
    required PlanningPeriodKind kind,
    required String periodKey,
  }) async {
    scope.ensureActive();
    final PlanningPeriodRow? row =
        await (db.select(db.planningPeriods)..where(
              (PlanningPeriods p) =>
                  p.profileId.equals(profileId) &
                  p.lifeAreaId.equals(lifeAreaId) &
                  p.kind.equals(kind.wire) &
                  p.periodKey.equals(periodKey),
            ))
            .getSingleOrNull();
    return row == null ? null : PlannerMapper.periodFromRow(row);
  }

  Future<PlanningPeriod?> findPeriodById(
    String profileId,
    String periodId,
  ) async {
    scope.ensureActive();
    final PlanningPeriodRow? row =
        await (db.select(db.planningPeriods)..where(
              (PlanningPeriods p) =>
                  p.profileId.equals(profileId) & p.id.equals(periodId),
            ))
            .getSingleOrNull();
    return row == null ? null : PlannerMapper.periodFromRow(row);
  }

  Future<void> insertPeriod(PlanningPeriod period) async {
    scope.ensureActive();
    await db
        .into(db.planningPeriods)
        .insert(PlannerMapper.periodToInsert(period));
  }

  Future<void> updatePeriod(PlanningPeriod period) async {
    scope.ensureActive();
    await (db.update(db.planningPeriods)..where(
          (PlanningPeriods p) =>
              p.profileId.equals(period.profileId.value) &
              p.id.equals(period.id.value),
        ))
        .write(PlannerMapper.periodToUpdate(period));
  }

  // ---- planning_entries ---------------------------------------------------

  Future<PlanningEntry?> findEntry(String profileId, String entryId) async {
    scope.ensureActive();
    final PlanningEntryRow? row =
        await (db.select(db.planningEntries)..where(
              (PlanningEntries e) =>
                  e.profileId.equals(profileId) & e.id.equals(entryId),
            ))
            .getSingleOrNull();
    return row == null ? null : PlannerMapper.entryFromRow(row);
  }

  Future<List<PlanningEntry>> entriesOf(
    String profileId,
    String periodId,
  ) async {
    scope.ensureActive();
    final List<PlanningEntryRow> rows =
        await (db.select(db.planningEntries)
              ..where(
                (PlanningEntries e) =>
                    e.profileId.equals(profileId) & e.periodId.equals(periodId),
              )
              ..orderBy(<OrderClauseGenerator<PlanningEntries>>[
                (PlanningEntries e) => OrderingTerm.asc(e.rank),
                (PlanningEntries e) => OrderingTerm.asc(e.id),
              ]))
            .get();
    return rows.map(PlannerMapper.entryFromRow).toList(growable: false);
  }

  Future<void> insertEntry(PlanningEntry entry, {String? addedEventId}) async {
    scope.ensureActive();
    await db
        .into(db.planningEntries)
        .insert(PlannerMapper.entryToInsert(entry, addedEventId: addedEventId));
  }

  Future<void> deleteEntry(String profileId, String entryId) async {
    scope.ensureActive();
    await (db.delete(db.planningEntries)..where(
          (PlanningEntries e) =>
              e.profileId.equals(profileId) & e.id.equals(entryId),
        ))
        .go();
  }

  /// The highest existing entry rank in a period, used to append at the end.
  Future<String?> lastEntryRank(String profileId, String periodId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT rank FROM planning_entries '
          'WHERE profile_id = ? AND period_id = ? '
          'ORDER BY rank DESC, id DESC LIMIT 1',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(periodId),
          ],
        )
        .get();
    return rows.isEmpty ? null : rows.single.data['rank'] as String;
  }

  // ---- planning_close_events / items / adjustments ------------------------

  Future<PlanningCloseEvent?> findCloseByPeriod(
    String profileId,
    String periodId,
  ) async {
    scope.ensureActive();
    final PlanningCloseEventRow? row =
        await (db.select(db.planningCloseEvents)..where(
              (PlanningCloseEvents c) =>
                  c.profileId.equals(profileId) & c.periodId.equals(periodId),
            ))
            .getSingleOrNull();
    return row == null ? null : PlannerMapper.closeFromRow(row);
  }

  Future<void> insertCloseEvent(PlanningCloseEvent event) async {
    scope.ensureActive();
    await db
        .into(db.planningCloseEvents)
        .insert(
          PlanningCloseEventsCompanion.insert(
            id: event.id,
            profileId: event.profileId,
            periodId: event.periodId,
            closedAtUtc: event.closedAtUtc,
            boundaryUtc: event.boundaryUtc,
            metricPolicyVersion: event.metricPolicyVersion,
            sourceCommitSeq: event.sourceCommitSeq,
            eligibleCount: event.eligibleCount,
            completedCount: event.completedCount,
            missedCount: event.missedCount,
            carriedCount: event.carriedCount,
            eligibleRootHash: event.eligibleRootHash,
            completedRootHash: event.completedRootHash,
            createdAtUtc: event.createdAtUtc,
          ),
        );
  }

  Future<void> insertCloseItem(
    PlanningCloseItem item, {
    required int nowUtc,
  }) async {
    scope.ensureActive();
    await db
        .into(db.planningCloseItems)
        .insert(
          PlanningCloseItemsCompanion.insert(
            profileId: item.profileId,
            closeEventId: item.closeEventId,
            entityType: item.entityType,
            entityId: item.entityId,
            isPlanned: Value<bool?>(item.isPlanned),
            isDue: Value<bool?>(item.isDue),
            taskDueDate: Value<String?>(item.taskDueDate),
            status: item.status,
            sourceEventId: Value<String?>(item.sourceEventId),
            createdAtUtc: nowUtc,
          ),
        );
  }

  Future<void> insertAdjustment(PlanningCloseAdjustment adjustment) async {
    scope.ensureActive();
    await db
        .into(db.planningCloseAdjustments)
        .insert(
          PlanningCloseAdjustmentsCompanion.insert(
            id: adjustment.id,
            profileId: adjustment.profileId,
            closeEventId: adjustment.closeEventId,
            kind: adjustment.kind.wire,
            sourceCommandId: Value<String?>(adjustment.sourceCommandId),
            sourceEventId: Value<String?>(adjustment.sourceEventId),
            sourceCommitSeq: Value<int?>(adjustment.sourceCommitSeq),
            reason: Value<String?>(adjustment.reason),
            affectedEntityType: Value<String?>(adjustment.affectedEntityType),
            affectedEntityId: Value<String?>(adjustment.affectedEntityId),
            affectedMetric: Value<String?>(adjustment.affectedMetric),
            priorClassification: Value<String?>(adjustment.priorClassification),
            currentClassification: Value<String?>(
              adjustment.currentClassification,
            ),
            delta: Value<int?>(adjustment.delta),
            metricPolicyVersion: adjustment.metricPolicyVersion,
            derivedSummaryJson: Value<String?>(adjustment.derivedSummaryJson),
            derivedRootHash: Value<String?>(adjustment.derivedRootHash),
            occurredAtUtc: adjustment.occurredAtUtc,
            supersedesId: Value<String?>(adjustment.supersedesId),
            createdAtUtc: adjustment.createdAtUtc,
          ),
        );
  }

  /// The current epoch stamped on outbox operations. Falls back to `0` before a
  /// sync profile link exists.
  Future<int> currentEpoch(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT COALESCE(MAX(epoch), 0) AS e FROM sync_cursors '
          'WHERE profile_id = ?',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return rows.single.data['e'] as int;
  }
}
