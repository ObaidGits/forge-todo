import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// Focus schema (data-model §3 "Focus and time"; R-FOCUS-001..006).
// ---------------------------------------------------------------------------
//
// Ownership:
//   * `focus_sessions`   direct-area owner `(profile_id, life_area_id)`; carries
//                        the timer truth (wall + monotonic anchors, boot id,
//                        accumulated duration) and the visible status
//                        projection. A partial unique index enforces at most one
//                        open session per profile (R-FOCUS-002/003).
//   * `focus_intervals`  inherited via `(profile_id, session_id)`; an immutable
//                        work/pause interval projection from the event log. A
//                        partial unique index enforces at most one open interval
//                        per profile; no-overlap is validated in the writing
//                        transaction (R-FOCUS-003).
//   * `focus_events`     inherited via `(profile_id, session_id)`; the immutable,
//                        append-only lifecycle/correction event log with wall +
//                        monotonic stamps and boot id (R-FOCUS-002/003/005).

/// A focus session: the anchored timer truth and visible status projection
/// (R-FOCUS-001, R-FOCUS-002, R-FOCUS-003, R-FOCUS-004).
@DataClassName('FocusSessionRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_focus_sessions_profile_id '
  'ON focus_sessions (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_focus_sessions_area_id '
  'ON focus_sessions (profile_id, life_area_id, id)',
)
// At most one open (running or paused) session per profile (R-FOCUS-003).
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_focus_sessions_open '
  'ON focus_sessions (profile_id) '
  "WHERE status IN ('running', 'paused') AND deleted_at_utc IS NULL",
)
@TableIndex.sql(
  'CREATE INDEX ix_focus_sessions_started '
  'ON focus_sessions (profile_id, started_at_utc, status) '
  'WHERE deleted_at_utc IS NULL',
)
@TableIndex(
  name: 'ix_focus_sessions_link',
  columns: {#profileId, #linkTargetType, #linkTargetId},
)
class FocusSessions extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get lifeAreaId => text()();
  TextColumn get linkTargetType => text().nullable()();
  TextColumn get linkTargetId => text().nullable()();
  TextColumn get mode => text()();
  TextColumn get preset => text().nullable()();
  IntColumn get plannedDurationSec => integer().nullable()();
  TextColumn get status => text()();
  IntColumn get wallAnchorUtc => integer()();
  IntColumn get monotonicAnchorMicros => integer()();
  TextColumn get bootSessionId => text()();
  IntColumn get accumulatedDurationSec => integer()();
  IntColumn get startedAtUtc => integer()();
  IntColumn get endedAtUtc => integer().nullable()();
  IntColumn get revision => integer().withDefault(const Constant<int>(1))();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();
  IntColumn get deletedAtUtc => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'UNIQUE (profile_id, life_area_id, id)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, life_area_id) REFERENCES life_areas (profile_id, id)',
    "CHECK (mode IN ('count_up', 'interval'))",
    "CHECK (status IN ('running', 'paused', 'completed', 'cancelled'))",
    "CHECK (link_target_type IS NULL OR link_target_type IN ('task', 'course', 'goal', 'habit'))",
    // A link is all-or-nothing: type and id are both present or both absent.
    ('CHECK ((link_target_type IS NULL AND link_target_id IS NULL) OR '
        '(link_target_type IS NOT NULL AND link_target_id IS NOT NULL))'),
    // An interval session carries a positive planned duration; a count-up
    // session carries none (R-FOCUS-001, R-FOCUS-004).
    ("CHECK ((mode = 'interval' AND planned_duration_sec IS NOT NULL AND "
        'planned_duration_sec > 0) OR '
        "(mode = 'count_up' AND planned_duration_sec IS NULL))"),
    'CHECK (accumulated_duration_sec >= 0)',
    'CHECK (monotonic_anchor_micros >= 0)',
    // A terminal session has an end instant; an open one does not.
    ("CHECK ((status IN ('completed', 'cancelled') AND ended_at_utc IS NOT NULL) "
        "OR (status IN ('running', 'paused') AND ended_at_utc IS NULL))"),
  ];
}

/// An immutable projected work/pause interval (R-FOCUS-003).
@DataClassName('FocusIntervalRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_focus_intervals_profile_id '
  'ON focus_intervals (profile_id, id)',
)
// At most one open interval per profile (R-FOCUS-003 one-open constraint).
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_focus_intervals_open '
  'ON focus_intervals (profile_id) WHERE ended_at_utc IS NULL',
)
@TableIndex(
  name: 'ix_focus_intervals_session',
  columns: {#profileId, #sessionId, #startedAtUtc},
)
@TableIndex(
  name: 'ix_focus_intervals_range',
  columns: {#profileId, #startedAtUtc, #endedAtUtc},
)
class FocusIntervals extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get sessionId => text()();
  TextColumn get intervalKind => text()();
  IntColumn get startedAtUtc => integer()();
  IntColumn get endedAtUtc => integer().nullable()();
  IntColumn get monotonicStartMicros => integer().nullable()();
  IntColumn get monotonicEndMicros => integer().nullable()();
  TextColumn get bootSessionId => text()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, session_id) REFERENCES focus_sessions (profile_id, id)',
    "CHECK (interval_kind IN ('work', 'pause'))",
    'CHECK (ended_at_utc IS NULL OR ended_at_utc >= started_at_utc)',
  ];
}

/// The immutable, append-only focus lifecycle event log (R-FOCUS-003).
@DataClassName('FocusEventRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_focus_events_command '
  'ON focus_events (profile_id, command_id) WHERE command_id IS NOT NULL',
)
@TableIndex(
  name: 'ix_focus_events_time',
  columns: {#profileId, #sessionId, #occurredAtUtc},
)
class FocusEvents extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get sessionId => text()();
  TextColumn get commandId => text().nullable()();
  TextColumn get eventKind => text()();
  IntColumn get wallAtUtc => integer()();
  IntColumn get monotonicMicros => integer().nullable()();
  TextColumn get bootSessionId => text()();
  TextColumn get payload => text().nullable()();
  IntColumn get payloadVersion => integer()();
  IntColumn get occurredAtUtc => integer()();
  TextColumn get supersedesId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, session_id) REFERENCES focus_sessions (profile_id, id)',
    ("CHECK (event_kind IN ('started', 'paused', 'resumed', 'ended', "
        "'cancelled', 'corrected', 'undone'))"),
  ];
}
