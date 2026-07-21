import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_schedule_version.dart';
import 'package:forge/features/tasks/domain/recurrence/task_occurrence.dart';
import 'package:forge/features/tasks/infrastructure/recurrence_mapper.dart';

/// A materialized occurrence row projection used inside a command body.
final class OccurrenceRecord {
  const OccurrenceRecord({
    required this.id,
    required this.taskId,
    required this.scheduleVersionId,
    required this.originalScheduleVersionId,
    required this.occurrenceKey,
    required this.status,
    required this.generatedVersion,
    this.occurrenceDueAtUtc,
    this.occurrenceTimezone,
  });

  final String id;
  final String taskId;
  final String scheduleVersionId;
  final String originalScheduleVersionId;
  final LocalDate occurrenceKey;
  final OccurrenceStatus status;
  final int generatedVersion;
  final int? occurrenceDueAtUtc;
  final String? occurrenceTimezone;
}

/// The most recent occurrence event of a task, used for undo.
final class OccurrenceEventRecord {
  const OccurrenceEventRecord({
    required this.id,
    required this.occurrenceId,
    required this.eventKind,
    required this.supersedesId,
  });

  final String id;
  final String occurrenceId;
  final OccurrenceEventKind eventKind;
  final String? supersedesId;
}

/// Transaction-scoped write access to the recurrence tables (R-TASK-005,
/// R-TASK-006, R-TASK-007).
///
/// Created per transaction by the unit of work and resolved from the session
/// repository set inside a command body (design.md §5). All schedule versions
/// and occurrence events are immutable once written; only the
/// `task_occurrences` status projection is updated in place.
final class RecurrenceWriteRepository {
  RecurrenceWriteRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;

  Future<void> insertScheduleVersion(
    RecurrenceScheduleVersion version, {
    required String profileId,
    required String taskId,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    await db
        .into(db.recurrenceRules)
        .insert(
          RecurrenceMapper.toInsert(
            version,
            profileId: profileId,
            taskId: taskId,
            nowUtc: nowUtc,
          ),
        );
  }

  Future<RecurrenceScheduleVersion?> findScheduleVersion(
    String profileId,
    String versionId,
  ) async {
    scope.ensureActive();
    final RecurrenceRuleRow? row =
        await (db.select(db.recurrenceRules)..where(
              (RecurrenceRules r) =>
                  r.profileId.equals(profileId) & r.id.equals(versionId),
            ))
            .getSingleOrNull();
    return row == null ? null : RecurrenceMapper.versionFromRow(row);
  }

  /// The open (non-closed) tail schedule version of a task's series, or null
  /// when the task has no recurrence.
  Future<RecurrenceScheduleVersion?> findOpenScheduleVersion(
    String profileId,
    String taskId,
  ) async {
    scope.ensureActive();
    final RecurrenceRuleRow? row =
        await (db.select(db.recurrenceRules)
              ..where(
                (RecurrenceRules r) =>
                    r.profileId.equals(profileId) &
                    r.taskId.equals(taskId) &
                    r.closedAtOccurrenceKey.isNull(),
              )
              ..orderBy(<OrderClauseGenerator<RecurrenceRules>>[
                (RecurrenceRules r) => OrderingTerm.desc(r.version),
              ])
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : RecurrenceMapper.versionFromRow(row);
  }

  Future<void> closeScheduleVersion(
    String profileId,
    String versionId,
    LocalDate closedAtOccurrenceKey,
    int nowUtc,
  ) async {
    scope.ensureActive();
    await (db.update(db.recurrenceRules)..where(
          (RecurrenceRules r) =>
              r.profileId.equals(profileId) & r.id.equals(versionId),
        ))
        .write(
          RecurrenceRulesCompanion(
            closedAtOccurrenceKey: Value<String?>(closedAtOccurrenceKey.iso),
            updatedAtUtc: Value<int>(nowUtc),
          ),
        );
  }

  /// The set of occurrence keys that must be skipped by the base pattern when
  /// resolving occurrences: exceptions ("this occurrence" delete) and overrides
  /// ("this occurrence" edit). Completed occurrences are real and excluded here.
  Future<Set<LocalDate>> exceptionKeys(String profileId, String taskId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT occurrence_key FROM task_occurrences '
          'WHERE profile_id = ? AND task_id = ? '
          "AND status IN ('skipped', 'overridden')",
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(taskId),
          ],
        )
        .get();
    return rows
        .map(
          (QueryRow r) => LocalDate.parse(r.data['occurrence_key'] as String),
        )
        .toSet();
  }

  Future<void> insertOccurrence({
    required String profileId,
    required String id,
    required String taskId,
    required String scheduleVersionId,
    required String originalScheduleVersionId,
    required LocalDate occurrenceKey,
    required OccurrenceStatus status,
    required int nowUtc,
    int? occurrenceDueAtUtc,
    String? occurrenceTimezone,
  }) async {
    scope.ensureActive();
    await db
        .into(db.taskOccurrences)
        .insert(
          TaskOccurrencesCompanion.insert(
            id: id,
            profileId: profileId,
            taskId: taskId,
            scheduleVersionId: scheduleVersionId,
            originalScheduleVersionId: originalScheduleVersionId,
            occurrenceKey: occurrenceKey.iso,
            status: status.wire,
            occurrenceDueAtUtc: Value<int?>(occurrenceDueAtUtc),
            occurrenceTimezone: Value<String?>(occurrenceTimezone),
            createdAtUtc: nowUtc,
            updatedAtUtc: nowUtc,
          ),
        );
  }

  Future<OccurrenceRecord?> findOpenOccurrence(
    String profileId,
    String taskId,
  ) async {
    scope.ensureActive();
    final TaskOccurrenceRow? row =
        await (db.select(db.taskOccurrences)
              ..where(
                (TaskOccurrences o) =>
                    o.profileId.equals(profileId) &
                    o.taskId.equals(taskId) &
                    o.status.equals(OccurrenceStatus.open.wire),
              )
              ..orderBy(<OrderClauseGenerator<TaskOccurrences>>[
                (TaskOccurrences o) => OrderingTerm.asc(o.occurrenceKey),
              ])
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _toRecord(row);
  }

  Future<OccurrenceRecord?> findOccurrenceByKey(
    String profileId,
    String taskId,
    LocalDate occurrenceKey,
  ) async {
    scope.ensureActive();
    final TaskOccurrenceRow? row =
        await (db.select(db.taskOccurrences)..where(
              (TaskOccurrences o) =>
                  o.profileId.equals(profileId) &
                  o.taskId.equals(taskId) &
                  o.occurrenceKey.equals(occurrenceKey.iso),
            ))
            .getSingleOrNull();
    return row == null ? null : _toRecord(row);
  }

  Future<OccurrenceRecord?> findOccurrenceById(
    String profileId,
    String occurrenceId,
  ) async {
    scope.ensureActive();
    final TaskOccurrenceRow? row =
        await (db.select(db.taskOccurrences)..where(
              (TaskOccurrences o) =>
                  o.profileId.equals(profileId) & o.id.equals(occurrenceId),
            ))
            .getSingleOrNull();
    return row == null ? null : _toRecord(row);
  }

  /// Re-points an existing occurrence at a successor schedule version (used by
  /// a "this and future" split when the effective key was already
  /// materialized), refreshing its status and due projection.
  Future<void> repointOccurrence({
    required String profileId,
    required String occurrenceId,
    required String scheduleVersionId,
    required OccurrenceStatus status,
    required int nowUtc,
    int? occurrenceDueAtUtc,
    String? occurrenceTimezone,
  }) async {
    scope.ensureActive();
    await (db.update(db.taskOccurrences)..where(
          (TaskOccurrences o) =>
              o.profileId.equals(profileId) & o.id.equals(occurrenceId),
        ))
        .write(
          TaskOccurrencesCompanion(
            scheduleVersionId: Value<String>(scheduleVersionId),
            status: Value<String>(status.wire),
            occurrenceDueAtUtc: Value<int?>(occurrenceDueAtUtc),
            occurrenceTimezone: Value<String?>(occurrenceTimezone),
            updatedAtUtc: Value<int>(nowUtc),
          ),
        );
  }

  Future<void> setOccurrenceStatus({
    required String profileId,
    required String occurrenceId,
    required OccurrenceStatus status,
    required int nowUtc,
    bool bumpGeneratedVersion = false,
  }) async {
    scope.ensureActive();
    if (bumpGeneratedVersion) {
      await db.customStatement(
        'UPDATE task_occurrences SET status = ?, '
        'generated_version = generated_version + 1, updated_at_utc = ? '
        'WHERE profile_id = ? AND id = ?',
        <Object?>[status.wire, nowUtc, profileId, occurrenceId],
      );
      return;
    }
    await (db.update(db.taskOccurrences)..where(
          (TaskOccurrences o) =>
              o.profileId.equals(profileId) & o.id.equals(occurrenceId),
        ))
        .write(
          TaskOccurrencesCompanion(
            status: Value<String>(status.wire),
            updatedAtUtc: Value<int>(nowUtc),
          ),
        );
  }

  Future<void> appendOccurrenceEvent({
    required String profileId,
    required String id,
    required String occurrenceId,
    required OccurrenceEventKind eventKind,
    required int payloadVersion,
    required int nowUtc,
    String? commandId,
    String? payload,
    String? supersedesId,
  }) async {
    scope.ensureActive();
    await db
        .into(db.taskOccurrenceEvents)
        .insert(
          TaskOccurrenceEventsCompanion.insert(
            id: id,
            profileId: profileId,
            occurrenceId: occurrenceId,
            commandId: Value<String?>(commandId),
            eventKind: eventKind.wire,
            payload: Value<String?>(payload),
            payloadVersion: payloadVersion,
            occurredAtUtc: nowUtc,
            supersedesId: Value<String?>(supersedesId),
          ),
        );
  }

  /// The most recent non-superseded occurrence event across a task's
  /// occurrences, used to compute the target of an undo.
  Future<OccurrenceEventRecord?> latestOccurrenceEvent(
    String profileId,
    String taskId,
  ) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT e.id AS id, e.occurrence_id AS occurrence_id, '
          'e.event_kind AS event_kind, e.supersedes_id AS supersedes_id '
          'FROM task_occurrence_events e '
          'JOIN task_occurrences o '
          '  ON o.profile_id = e.profile_id AND o.id = e.occurrence_id '
          'WHERE e.profile_id = ? AND o.task_id = ? '
          'ORDER BY e.occurred_at_utc DESC, e.id DESC LIMIT 1',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(taskId),
          ],
        )
        .get();
    if (rows.isEmpty) {
      return null;
    }
    final Map<String, Object?> data = rows.single.data;
    return OccurrenceEventRecord(
      id: data['id'] as String,
      occurrenceId: data['occurrence_id'] as String,
      eventKind: OccurrenceEventKind.fromWire(data['event_kind'] as String),
      supersedesId: data['supersedes_id'] as String?,
    );
  }

  OccurrenceRecord _toRecord(TaskOccurrenceRow row) => OccurrenceRecord(
    id: row.id,
    taskId: row.taskId,
    scheduleVersionId: row.scheduleVersionId,
    originalScheduleVersionId: row.originalScheduleVersionId,
    occurrenceKey: LocalDate.parse(row.occurrenceKey),
    status: OccurrenceStatus.fromWire(row.status),
    generatedVersion: row.generatedVersion,
    occurrenceDueAtUtc: row.occurrenceDueAtUtc,
    occurrenceTimezone: row.occurrenceTimezone,
  );
}
