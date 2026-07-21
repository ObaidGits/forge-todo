import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/habits/domain/habit.dart';
import 'package:forge/features/habits/domain/habit_checkin.dart';
import 'package:forge/features/habits/domain/habit_occurrence_key.dart';
import 'package:forge/features/habits/domain/habit_occurrence_status.dart';
import 'package:forge/features/habits/domain/habit_schedule_version.dart';
import 'package:forge/features/habits/infrastructure/habit_mapper.dart';

/// A materialized occurrence row projection used inside a command body.
final class HabitOccurrenceRecord {
  const HabitOccurrenceRecord({
    required this.id,
    required this.habitId,
    required this.scheduleVersionId,
    required this.occurrenceKey,
    required this.anchorDate,
    required this.status,
    required this.normalizedTotal,
    required this.isPaused,
    this.closedAtUtc,
  });

  final String id;
  final String habitId;
  final String scheduleVersionId;
  final String occurrenceKey;
  final LocalDate anchorDate;
  final HabitOccurrenceStatus status;
  final int normalizedTotal;
  final bool isPaused;
  final int? closedAtUtc;
}

/// A current (non-superseded) check-in row projection.
final class HabitCheckinRecord {
  const HabitCheckinRecord({
    required this.id,
    required this.logicalId,
    required this.kind,
    required this.normalizedValue,
  });

  final String id;
  final String logicalId;
  final HabitCheckinKind kind;
  final int normalizedValue;
}

/// Transaction-scoped write access to the habit tables (R-HABIT-001..007).
///
/// Created per transaction by the unit of work and resolved from the session
/// repository set inside a command body (design.md §5). Schedule versions and
/// check-in records are immutable once written; the `habit_occurrences` status
/// projection is updated in place, and a check-in correction supersedes rather
/// than rewrites a prior observation.
final class HabitWriteRepository {
  HabitWriteRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;

  // ---- habits -------------------------------------------------------------

  Future<void> insertHabit(Habit habit, {required String profileId}) async {
    scope.ensureActive();
    await db
        .into(db.habits)
        .insert(HabitMapper.habitToInsert(habit, profileId: profileId));
  }

  Future<Habit?> findHabit(String profileId, String habitId) async {
    scope.ensureActive();
    final HabitRow? row =
        await (db.select(db.habits)..where(
              (Habits h) =>
                  h.profileId.equals(profileId) & h.id.equals(habitId),
            ))
            .getSingleOrNull();
    return row == null ? null : HabitMapper.habitFromRow(row);
  }

  /// Every current (non-tombstoned) habit id for [profileId], used by the
  /// unified-search source rebuild path to regenerate `search_documents` from
  /// authoritative rows (R-SEARCH-001). Archived habits remain searchable, so
  /// only soft-deleted rows are excluded.
  Future<List<String>> activeHabitIds(String profileId) async {
    scope.ensureActive();
    final List<HabitRow> rows =
        await (db.select(db.habits)
              ..where(
                (Habits h) =>
                    h.profileId.equals(profileId) & h.deletedAtUtc.isNull(),
              )
              ..orderBy(<OrderClauseGenerator<Habits>>[
                (Habits h) => OrderingTerm.asc(h.id),
              ]))
            .get();
    return rows.map((HabitRow r) => r.id).toList(growable: false);
  }

  Future<void> updateHabit(Habit habit, {required String profileId}) async {
    scope.ensureActive();
    await (db.update(db.habits)..where(
          (Habits h) =>
              h.profileId.equals(profileId) & h.id.equals(habit.id.value),
        ))
        .write(
          HabitsCompanion(
            title: Value<String>(habit.title),
            currentScheduleVersionId: Value<String>(
              habit.currentScheduleVersionId,
            ),
            status: Value<String>(habit.status.wire),
            pausedAtUtc: Value<int?>(habit.pausedAtUtc),
            rank: Value<String>(habit.rank),
            revision: Value<int>(habit.revision),
            updatedAtUtc: Value<int>(habit.updatedAtUtc),
            deletedAtUtc: Value<int?>(habit.deletedAtUtc),
          ),
        );
  }

  // ---- schedule versions --------------------------------------------------

  Future<void> insertScheduleVersion(
    HabitScheduleVersion version, {
    required String profileId,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    await db
        .into(db.habitSchedules)
        .insert(
          HabitMapper.versionToInsert(
            version,
            profileId: profileId,
            nowUtc: nowUtc,
          ),
        );
  }

  Future<HabitScheduleVersion?> findScheduleVersion(
    String profileId,
    String versionId,
  ) async {
    scope.ensureActive();
    final HabitScheduleRow? row =
        await (db.select(db.habitSchedules)..where(
              (HabitSchedules s) =>
                  s.profileId.equals(profileId) & s.id.equals(versionId),
            ))
            .getSingleOrNull();
    return row == null ? null : HabitMapper.versionFromRow(row);
  }

  /// The open (non-closed) tail schedule version of a habit, or null.
  Future<HabitScheduleVersion?> findOpenScheduleVersion(
    String profileId,
    String habitId,
  ) async {
    scope.ensureActive();
    final HabitScheduleRow? row =
        await (db.select(db.habitSchedules)
              ..where(
                (HabitSchedules s) =>
                    s.profileId.equals(profileId) &
                    s.habitId.equals(habitId) &
                    s.closedAtOccurrenceKey.isNull(),
              )
              ..orderBy(<OrderClauseGenerator<HabitSchedules>>[
                (HabitSchedules s) => OrderingTerm.desc(s.version),
              ])
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : HabitMapper.versionFromRow(row);
  }

  /// The immutable schedule version governing occurrences whose anchor is
  /// [anchor]: the newest version whose effective key is `<= anchor` and whose
  /// close bound (if any) is strictly after [anchor].
  Future<HabitScheduleVersion?> findVersionEffectiveAt(
    String profileId,
    String habitId,
    LocalDate anchor,
  ) async {
    scope.ensureActive();
    final HabitScheduleRow? row =
        await (db.select(db.habitSchedules)
              ..where(
                (HabitSchedules s) =>
                    s.profileId.equals(profileId) &
                    s.habitId.equals(habitId) &
                    s.effectiveOccurrenceKey.isSmallerOrEqualValue(anchor.iso) &
                    (s.closedAtOccurrenceKey.isNull() |
                        s.closedAtOccurrenceKey.isBiggerThanValue(anchor.iso)),
              )
              ..orderBy(<OrderClauseGenerator<HabitSchedules>>[
                (HabitSchedules s) => OrderingTerm.desc(s.version),
              ])
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : HabitMapper.versionFromRow(row);
  }

  Future<void> closeScheduleVersion(
    String profileId,
    String versionId,
    LocalDate closedAtOccurrenceKey,
    int nowUtc,
  ) async {
    scope.ensureActive();
    await (db.update(db.habitSchedules)..where(
          (HabitSchedules s) =>
              s.profileId.equals(profileId) & s.id.equals(versionId),
        ))
        .write(
          HabitSchedulesCompanion(
            closedAtOccurrenceKey: Value<String?>(closedAtOccurrenceKey.iso),
            updatedAtUtc: Value<int>(nowUtc),
          ),
        );
  }

  // ---- occurrences --------------------------------------------------------

  Future<void> insertOccurrence({
    required String profileId,
    required String id,
    required String habitId,
    required String scheduleVersionId,
    required HabitOccurrenceKey occurrenceKey,
    required HabitOccurrenceStatus status,
    required int nowUtc,
    int normalizedTotal = 0,
    bool isPaused = false,
    int? closedAtUtc,
    int? sourceCommitSeq,
  }) async {
    scope.ensureActive();
    await db
        .into(db.habitOccurrences)
        .insert(
          HabitOccurrencesCompanion.insert(
            id: id,
            profileId: profileId,
            habitId: habitId,
            scheduleVersionId: scheduleVersionId,
            occurrenceKey: occurrenceKey.value,
            anchorDate: occurrenceKey.anchor.iso,
            status: status.wire,
            normalizedTotal: Value<int>(normalizedTotal),
            isPaused: Value<bool>(isPaused),
            closedAtUtc: Value<int?>(closedAtUtc),
            sourceCommitSeq: Value<int?>(sourceCommitSeq),
            createdAtUtc: nowUtc,
            updatedAtUtc: nowUtc,
          ),
        );
  }

  Future<HabitOccurrenceRecord?> findOccurrenceByKey(
    String profileId,
    String habitId,
    String occurrenceKey,
  ) async {
    scope.ensureActive();
    final HabitOccurrenceRow? row =
        await (db.select(db.habitOccurrences)..where(
              (HabitOccurrences o) =>
                  o.profileId.equals(profileId) &
                  o.habitId.equals(habitId) &
                  o.occurrenceKey.equals(occurrenceKey),
            ))
            .getSingleOrNull();
    return row == null ? null : _toOccurrenceRecord(row);
  }

  Future<HabitOccurrenceRecord?> findOccurrenceById(
    String profileId,
    String occurrenceId,
  ) async {
    scope.ensureActive();
    final HabitOccurrenceRow? row =
        await (db.select(db.habitOccurrences)..where(
              (HabitOccurrences o) =>
                  o.profileId.equals(profileId) & o.id.equals(occurrenceId),
            ))
            .getSingleOrNull();
    return row == null ? null : _toOccurrenceRecord(row);
  }

  Future<void> updateOccurrenceProjection({
    required String profileId,
    required String occurrenceId,
    required HabitOccurrenceStatus status,
    required int normalizedTotal,
    required int nowUtc,
    bool? isPaused,
    int? closedAtUtc,
    bool clearClosedAt = false,
    int? sourceCommitSeq,
  }) async {
    scope.ensureActive();
    await (db.update(db.habitOccurrences)..where(
          (HabitOccurrences o) =>
              o.profileId.equals(profileId) & o.id.equals(occurrenceId),
        ))
        .write(
          HabitOccurrencesCompanion(
            status: Value<String>(status.wire),
            normalizedTotal: Value<int>(normalizedTotal),
            isPaused: isPaused == null
                ? const Value<bool>.absent()
                : Value<bool>(isPaused),
            closedAtUtc: clearClosedAt
                ? const Value<int?>(null)
                : (closedAtUtc == null
                      ? const Value<int?>.absent()
                      : Value<int?>(closedAtUtc)),
            sourceCommitSeq: sourceCommitSeq == null
                ? const Value<int?>.absent()
                : Value<int?>(sourceCommitSeq),
            updatedAtUtc: Value<int>(nowUtc),
          ),
        );
  }

  // ---- check-ins ----------------------------------------------------------

  /// Appends an immutable check-in record. When [supersedesId] is set, the
  /// superseded record's `is_current` flag is cleared in the same transaction
  /// so exactly one current record survives per logical observation.
  Future<void> appendCheckin({
    required String profileId,
    required String id,
    required String habitId,
    required String occurrenceId,
    required String logicalId,
    required HabitCheckinKind kind,
    required int version,
    required int nowUtc,
    double? rawValue,
    String? rawUnit,
    int? normalizedValue,
    String? note,
    String? supersedesId,
  }) async {
    scope.ensureActive();
    if (supersedesId != null) {
      await (db.update(db.habitCheckins)..where(
            (HabitCheckins c) =>
                c.profileId.equals(profileId) & c.id.equals(supersedesId),
          ))
          .write(const HabitCheckinsCompanion(isCurrent: Value<bool>(false)));
    }
    await db
        .into(db.habitCheckins)
        .insert(
          HabitCheckinsCompanion.insert(
            id: id,
            profileId: profileId,
            habitId: habitId,
            occurrenceId: occurrenceId,
            logicalId: logicalId,
            eventKind: kind.wire,
            rawValue: Value<double?>(rawValue),
            rawUnit: Value<String?>(rawUnit),
            normalizedValue: Value<int?>(normalizedValue),
            note: Value<String?>(note),
            recordedAtUtc: nowUtc,
            version: version,
            supersedesId: Value<String?>(supersedesId),
            isCurrent: true,
            createdAtUtc: nowUtc,
          ),
        );
  }

  /// The current (non-superseded) observations for an occurrence, ordered by
  /// record time.
  Future<List<HabitCheckinRecord>> currentCheckins(
    String profileId,
    String occurrenceId,
  ) async {
    scope.ensureActive();
    final List<HabitCheckinRow> rows =
        await (db.select(db.habitCheckins)
              ..where(
                (HabitCheckins c) =>
                    c.profileId.equals(profileId) &
                    c.occurrenceId.equals(occurrenceId) &
                    c.isCurrent.equals(true),
              )
              ..orderBy(<OrderClauseGenerator<HabitCheckins>>[
                (HabitCheckins c) => OrderingTerm.asc(c.recordedAtUtc),
              ]))
            .get();
    return rows
        .map(
          (HabitCheckinRow r) => HabitCheckinRecord(
            id: r.id,
            logicalId: r.logicalId,
            kind: HabitCheckinKind.fromWire(r.eventKind),
            normalizedValue: r.normalizedValue ?? 0,
          ),
        )
        .toList(growable: false);
  }

  /// The current check-in for a logical observation id, or null.
  Future<HabitCheckinRecord?> findCurrentCheckinByLogical(
    String profileId,
    String logicalId,
  ) async {
    scope.ensureActive();
    final HabitCheckinRow? row =
        await (db.select(db.habitCheckins)..where(
              (HabitCheckins c) =>
                  c.profileId.equals(profileId) &
                  c.logicalId.equals(logicalId) &
                  c.isCurrent.equals(true),
            ))
            .getSingleOrNull();
    return row == null
        ? null
        : HabitCheckinRecord(
            id: row.id,
            logicalId: row.logicalId,
            kind: HabitCheckinKind.fromWire(row.eventKind),
            normalizedValue: row.normalizedValue ?? 0,
          );
  }

  /// The occurrence a logical observation's current check-in belongs to, or
  /// null when no current record exists for [logicalId].
  Future<HabitOccurrenceRecord?> findOccurrenceForLogicalCheckin(
    String profileId,
    String logicalId,
  ) async {
    scope.ensureActive();
    final HabitCheckinRow? checkin =
        await (db.select(db.habitCheckins)..where(
              (HabitCheckins c) =>
                  c.profileId.equals(profileId) &
                  c.logicalId.equals(logicalId) &
                  c.isCurrent.equals(true),
            ))
            .getSingleOrNull();
    if (checkin == null) {
      return null;
    }
    return findOccurrenceById(profileId, checkin.occurrenceId);
  }

  // ---- pauses -------------------------------------------------------------

  Future<void> insertPause({
    required String profileId,
    required String id,
    required String habitId,
    required LocalDate startDate,
    required int nowUtc,
    LocalDate? endDate,
    String? reason,
  }) async {
    scope.ensureActive();
    await db
        .into(db.habitPauses)
        .insert(
          HabitPausesCompanion.insert(
            id: id,
            profileId: profileId,
            habitId: habitId,
            startDate: startDate.iso,
            endDate: Value<String?>(endDate?.iso),
            reason: Value<String?>(reason),
            createdAtUtc: nowUtc,
          ),
        );
  }

  /// Whether an active pause span of [habitId] covers [anchor].
  Future<bool> isAnchorPaused(
    String profileId,
    String habitId,
    LocalDate anchor,
  ) async {
    scope.ensureActive();
    final HabitPauseRow? row =
        await (db.select(db.habitPauses)
              ..where(
                (HabitPauses p) =>
                    p.profileId.equals(profileId) &
                    p.habitId.equals(habitId) &
                    p.startDate.isSmallerOrEqualValue(anchor.iso) &
                    (p.endDate.isNull() |
                        p.endDate.isBiggerOrEqualValue(anchor.iso)),
              )
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  HabitOccurrenceRecord _toOccurrenceRecord(HabitOccurrenceRow row) =>
      HabitOccurrenceRecord(
        id: row.id,
        habitId: row.habitId,
        scheduleVersionId: row.scheduleVersionId,
        occurrenceKey: row.occurrenceKey,
        anchorDate: LocalDate.parse(row.anchorDate),
        status: HabitOccurrenceStatus.fromWire(row.status),
        normalizedTotal: row.normalizedTotal,
        isPaused: row.isPaused,
        closedAtUtc: row.closedAtUtc,
      );
}
