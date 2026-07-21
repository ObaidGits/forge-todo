import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/focus/domain/focus_event.dart';
import 'package:forge/features/focus/domain/focus_interval.dart';
import 'package:forge/features/focus/domain/focus_link.dart';
import 'package:forge/features/focus/domain/focus_session.dart';
import 'package:forge/features/focus/infrastructure/focus_mapper.dart';

/// Transaction-scoped write access to the focus tables (R-FOCUS-001..005).
///
/// Created per transaction by the unit of work and resolved from the session
/// repository set inside a command body (design.md §5). The shared [scope]
/// rejects any use after the owning transaction completes. Session rows carry
/// the timer truth and visible status projection; intervals and events are
/// append-only (only interval end/timestamps are filled when a segment closes).
final class FocusWriteRepository {
  FocusWriteRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;

  /// Owner tables that exist and can be existence-validated for a link target.
  /// Every release-present link kind is checked against its profile-scoped
  /// owner table so a link to a missing or cross-profile entity is rejected
  /// (R-FOCUS-001, R-GEN-002). The habits owner table exists as of Wave 6, so
  /// habit links are now existence-validated like the others.
  static const Map<FocusLinkType, String> _linkOwnerTable =
      <FocusLinkType, String>{
        FocusLinkType.task: 'tasks',
        FocusLinkType.learningResource: 'courses',
        FocusLinkType.goal: 'goals',
        FocusLinkType.habit: 'habits',
      };

  // ---- sessions -----------------------------------------------------------

  Future<FocusSession?> findSession(String profileId, String sessionId) async {
    scope.ensureActive();
    final FocusSessionRow? row =
        await (db.select(db.focusSessions)..where(
              (FocusSessions s) =>
                  s.profileId.equals(profileId) & s.id.equals(sessionId),
            ))
            .getSingleOrNull();
    return row == null ? null : FocusMapper.sessionFromRow(row);
  }

  /// The single open (running or paused) session for [profileId], or null.
  Future<FocusSession?> findOpenSession(String profileId) async {
    scope.ensureActive();
    final FocusSessionRow? row =
        await (db.select(db.focusSessions)..where(
              (FocusSessions s) =>
                  s.profileId.equals(profileId) &
                  s.deletedAtUtc.isNull() &
                  s.status.isIn(<String>['running', 'paused']),
            ))
            .getSingleOrNull();
    return row == null ? null : FocusMapper.sessionFromRow(row);
  }

  Future<void> insertSession(FocusSession session) async {
    scope.ensureActive();
    await db
        .into(db.focusSessions)
        .insert(FocusMapper.sessionToInsert(session));
  }

  Future<void> updateSession(FocusSession session) async {
    scope.ensureActive();
    await (db.update(db.focusSessions)..where(
          (FocusSessions s) =>
              s.profileId.equals(session.profileId.value) &
              s.id.equals(session.id.value),
        ))
        .write(FocusMapper.sessionToUpdate(session));
  }

  /// True when a link target exists for [profileId]. Returns true without a
  /// lookup for target types whose owner table is not yet present.
  Future<bool> linkTargetExists(String profileId, FocusLink link) async {
    scope.ensureActive();
    final String? table = _linkOwnerTable[link.type];
    if (table == null) {
      return true;
    }
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT 1 FROM $table WHERE profile_id = ? AND id = ? LIMIT 1',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(link.targetId),
          ],
        )
        .get();
    return rows.isNotEmpty;
  }

  // ---- intervals ----------------------------------------------------------

  /// The single open interval for [profileId] (end is null), or null.
  Future<FocusInterval?> findOpenInterval(String profileId) async {
    scope.ensureActive();
    final FocusIntervalRow? row =
        await (db.select(db.focusIntervals)..where(
              (FocusIntervals i) =>
                  i.profileId.equals(profileId) & i.endedAtUtc.isNull(),
            ))
            .getSingleOrNull();
    return row == null ? null : FocusMapper.intervalFromRow(row);
  }

  Future<void> insertInterval(FocusInterval interval) async {
    scope.ensureActive();
    await db
        .into(db.focusIntervals)
        .insert(FocusMapper.intervalToInsert(interval));
  }

  /// Closes an open interval by stamping its end. The interval's start facts
  /// are never touched (R-FOCUS-003 immutable projection).
  Future<void> closeInterval({
    required String profileId,
    required String intervalId,
    required int endedAtUtc,
    int? monotonicEndMicros,
  }) async {
    scope.ensureActive();
    await (db.update(db.focusIntervals)..where(
          (FocusIntervals i) =>
              i.profileId.equals(profileId) & i.id.equals(intervalId),
        ))
        .write(
          FocusIntervalsCompanion(
            endedAtUtc: Value<int>(endedAtUtc),
            monotonicEndMicros: Value<int?>(monotonicEndMicros),
          ),
        );
  }

  /// Whether inserting a closed interval spanning `[startUtc, endUtc)` would
  /// overlap any existing interval for [profileId] (R-FOCUS-003 no-overlap).
  /// Touching boundaries (end == start) do not count as overlap.
  Future<bool> wouldOverlap({
    required String profileId,
    required int startUtc,
    required int endUtc,
  }) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT 1 FROM focus_intervals WHERE profile_id = ? '
          'AND started_at_utc < ? '
          'AND (ended_at_utc IS NULL OR ended_at_utc > ?) LIMIT 1',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<int>(endUtc),
            Variable<int>(startUtc),
          ],
        )
        .get();
    return rows.isNotEmpty;
  }

  // ---- events -------------------------------------------------------------

  Future<void> insertEvent(FocusEvent event) async {
    scope.ensureActive();
    await db.into(db.focusEvents).insert(FocusMapper.eventToInsert(event));
  }
}
