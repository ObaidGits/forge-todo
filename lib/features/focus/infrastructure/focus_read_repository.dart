import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/time_span.dart';
import 'package:forge/features/focus/application/focus_duration_contract.dart';
import 'package:forge/features/focus/application/focus_session_read_contract.dart';
import 'package:forge/features/focus/application/focus_today_contract.dart';
import 'package:forge/features/focus/domain/focus_event.dart';
import 'package:forge/features/focus/domain/focus_interval.dart';
import 'package:forge/features/focus/domain/focus_interval_kind.dart';
import 'package:forge/features/focus/domain/focus_link.dart';
import 'package:forge/features/focus/domain/focus_repository.dart';
import 'package:forge/features/focus/domain/focus_session.dart';
import 'package:forge/features/focus/infrastructure/focus_mapper.dart';

/// Read model over the focus tables (R-FOCUS-001..005).
///
/// Queries run outside a write transaction and re-project purely from persisted
/// rows, so every value survives a process restart. Combined focus duration is
/// computed by unioning closed work intervals so overlapping time is counted
/// exactly once (R-FOCUS-005).
final class FocusReadRepository
    implements
        FocusDurationContract,
        FocusTodayContract,
        FocusSessionReadContract,
        FocusRepository {
  FocusReadRepository(this._db);

  final ForgeSchemaDatabase _db;

  /// The read-only detail projection of one session, or null when absent
  /// (R-FOCUS-003). A pure read: it never mutates any focus row (R-HOME-005).
  @override
  Future<FocusSessionDetail?> sessionDetail(
    ProfileId profileId,
    FocusSessionId sessionId,
  ) async {
    final FocusSession? session = await findSession(profileId, sessionId);
    if (session == null || session.isDeleted) {
      return null;
    }
    final List<FocusInterval> projected = await intervals(profileId, sessionId);
    return FocusSessionDetail(
      sessionId: session.id.value,
      statusWire: session.status.wire,
      modeWire: session.mode.wire,
      accumulatedDurationSec: session.accumulatedDurationSec,
      plannedDurationSec: session.plannedDurationSec,
      linkLabel: session.link?.type.wire,
      startedAtUtc: session.startedAtUtc,
      endedAtUtc: session.endedAtUtc,
      intervals: projected
          .map(
            (FocusInterval i) => FocusIntervalView(
              kindWire: i.kind.wire,
              startedAtUtc: i.startedAtUtc,
              endedAtUtc: i.endedAtUtc,
            ),
          )
          .toList(growable: false),
    );
  }

  /// The single open focus session mapped onto the Today snapshot, or null when
  /// none is open (R-HOME-001, R-FOCUS-003). Optionally scoped to [lifeAreaId].
  /// A pure read: it never mutates any focus row (R-HOME-005).
  @override
  Future<FocusTodaySnapshot?> activeSession(
    ProfileId profileId, {
    LifeAreaId? lifeAreaId,
  }) async {
    final FocusSession? session = await openSession(profileId);
    if (session == null) {
      return null;
    }
    if (lifeAreaId != null && session.lifeAreaId.value != lifeAreaId.value) {
      return null;
    }
    return FocusTodaySnapshot(
      sessionId: session.id.value,
      statusWire: session.status.wire,
      modeWire: session.mode.wire,
      accumulatedDurationSec: session.accumulatedDurationSec,
      plannedDurationSec: session.plannedDurationSec,
      linkLabel: _linkLabel(session.link),
    );
  }

  static String? _linkLabel(FocusLink? link) => link?.type.wire;

  @override
  Future<FocusSession?> findSession(
    ProfileId profileId,
    FocusSessionId sessionId,
  ) async {
    final FocusSessionRow? row =
        await (_db.select(_db.focusSessions)..where(
              (FocusSessions s) =>
                  s.profileId.equals(profileId.value) &
                  s.id.equals(sessionId.value),
            ))
            .getSingleOrNull();
    return row == null ? null : FocusMapper.sessionFromRow(row);
  }

  @override
  Future<FocusSession?> openSession(ProfileId profileId) async {
    final FocusSessionRow? row =
        await (_db.select(_db.focusSessions)..where(
              (FocusSessions s) =>
                  s.profileId.equals(profileId.value) &
                  s.deletedAtUtc.isNull() &
                  s.status.isIn(<String>['running', 'paused']),
            ))
            .getSingleOrNull();
    return row == null ? null : FocusMapper.sessionFromRow(row);
  }

  @override
  Future<List<FocusEvent>> events(
    ProfileId profileId,
    FocusSessionId sessionId,
  ) async {
    final List<FocusEventRow> rows =
        await (_db.select(_db.focusEvents)
              ..where(
                (FocusEvents e) =>
                    e.profileId.equals(profileId.value) &
                    e.sessionId.equals(sessionId.value),
              )
              ..orderBy(<OrderClauseGenerator<FocusEvents>>[
                (FocusEvents e) => OrderingTerm.asc(e.occurredAtUtc),
                (FocusEvents e) => OrderingTerm.asc(e.id),
              ]))
            .get();
    return rows.map(FocusMapper.eventFromRow).toList(growable: false);
  }

  @override
  Future<List<FocusInterval>> intervals(
    ProfileId profileId,
    FocusSessionId sessionId,
  ) async {
    final List<FocusIntervalRow> rows =
        await (_db.select(_db.focusIntervals)
              ..where(
                (FocusIntervals i) =>
                    i.profileId.equals(profileId.value) &
                    i.sessionId.equals(sessionId.value),
              )
              ..orderBy(<OrderClauseGenerator<FocusIntervals>>[
                (FocusIntervals i) => OrderingTerm.asc(i.startedAtUtc),
                (FocusIntervals i) => OrderingTerm.asc(i.id),
              ]))
            .get();
    return rows.map(FocusMapper.intervalFromRow).toList(growable: false);
  }

  /// The unioned focus work seconds over `[rangeStartUtc, rangeEndUtc)`,
  /// optionally scoped to a life area. Only closed [FocusIntervalKind.work]
  /// intervals count, and overlapping ones are unioned (R-FOCUS-005).
  @override
  Future<int> focusDurationSec(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
  }) async {
    final List<TimeSpan> spans = await focusWorkSpans(
      profileId,
      rangeStartUtc: rangeStartUtc,
      rangeEndUtc: rangeEndUtc,
      lifeAreaId: lifeAreaId,
    );
    return IntervalUnion.unionSeconds(spans);
  }

  /// The closed focus work spans overlapping the range, clipped to it, so the
  /// insights feature can union them with study spans without double counting
  /// (R-FOCUS-005, R-INSIGHT-001).
  @override
  Future<List<TimeSpan>> focusWorkSpans(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
  }) async {
    final StringBuffer sql = StringBuffer(
      'SELECT i.started_at_utc AS s, i.ended_at_utc AS e '
      'FROM focus_intervals i '
      'JOIN focus_sessions fs ON fs.profile_id = i.profile_id '
      'AND fs.id = i.session_id '
      'WHERE i.profile_id = ? AND i.interval_kind = ? '
      'AND i.ended_at_utc IS NOT NULL '
      'AND i.started_at_utc < ? AND i.ended_at_utc > ? '
      'AND fs.deleted_at_utc IS NULL',
    );
    final List<Variable<Object>> vars = <Variable<Object>>[
      Variable<String>(profileId.value),
      const Variable<String>('work'),
      Variable<int>(rangeEndUtc),
      Variable<int>(rangeStartUtc),
    ];
    if (lifeAreaId != null) {
      sql.write(' AND fs.life_area_id = ?');
      vars.add(Variable<String>(lifeAreaId.value));
    }
    final List<QueryRow> rows = await _db
        .customSelect(sql.toString(), variables: vars)
        .get();
    return rows
        .map((QueryRow r) {
          final int start = r.data['s'] as int;
          final int end = r.data['e'] as int;
          // Clip each interval to the requested range before unioning.
          final int clippedStart = start < rangeStartUtc
              ? rangeStartUtc
              : start;
          final int clippedEnd = end > rangeEndUtc ? rangeEndUtc : end;
          return TimeSpan(startUtc: clippedStart, endUtc: clippedEnd);
        })
        .toList(growable: false);
  }
}
