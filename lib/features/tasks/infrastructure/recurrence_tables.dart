import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// Recurrence schema (data-model §3 "Tasks and reminders"; R-TASK-005,
// R-TASK-006, R-TASK-007, R-GEN-004).
// ---------------------------------------------------------------------------
//
// A recurring task is a series definition plus append-only occurrence history.
// All three tables are inherited-area owners: they derive their Life Area from
// the owning `tasks` row through the composite `(profile_id, task_id)` foreign
// key, so a recurrence never carries a redundant area (data-model §1).
//
//  * `recurrence_rules`      immutable schedule versions of a series.
//  * `task_occurrences`      the current status projection per occurrence key.
//  * `task_occurrence_events`the append-only, immutable event log.
//
// Completing an occurrence appends events and advances the projection; it never
// rewrites the schedule version that generated the history (R-TASK-006).
// Editing "this and future" closes a version and appends a successor; generated
// keys and events stay immutable (R-TASK-007).

/// Immutable schedule version of a recurring task series.
@DataClassName('RecurrenceRuleRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_recurrence_rules_profile_id '
  'ON recurrence_rules (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_recurrence_rules_series_version '
  'ON recurrence_rules (profile_id, series_id, version)',
)
@TableIndex(name: 'ix_recurrence_rules_task', columns: {#profileId, #taskId})
@TableIndex(
  name: 'ix_recurrence_rules_effective',
  columns: {#profileId, #seriesId, #effectiveOccurrenceKey},
)
class RecurrenceRules extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get taskId => text()();
  TextColumn get seriesId => text()();
  IntColumn get version => integer()();
  TextColumn get predecessorId => text().nullable()();
  TextColumn get effectiveOccurrenceKey => text()();
  TextColumn get closedAtOccurrenceKey => text().nullable()();
  TextColumn get frequency => text()();
  IntColumn get interval => integer().withDefault(const Constant<int>(1))();
  TextColumn get byWeekdays => text().nullable()();
  TextColumn get byMonthDays => text().nullable()();
  IntColumn get countLimit => integer().nullable()();
  TextColumn get untilDate => text().nullable()();
  TextColumn get timezoneId => text()();
  TextColumn get startDate => text()();
  IntColumn get timeOfDaySeconds => integer().nullable()();
  IntColumn get strategyVersion =>
      integer().withDefault(const Constant<int>(1))();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, task_id) REFERENCES tasks (profile_id, id)',
    "CHECK (frequency IN ('daily', 'weekly', 'monthly', 'yearly'))",
    'CHECK ("interval" >= 1)',
    'CHECK (version >= 1)',
    'CHECK (strategy_version >= 1)',
    'CHECK (count_limit IS NULL OR count_limit >= 1)',
    // A version cannot both be COUNT- and UNTIL-bounded.
    'CHECK (NOT (count_limit IS NOT NULL AND until_date IS NOT NULL))',
    ('CHECK (time_of_day_seconds IS NULL OR '
        '(time_of_day_seconds >= 0 AND time_of_day_seconds < 86400))'),
  ];
}

/// The current status projection of one materialized occurrence key.
@DataClassName('TaskOccurrenceRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_task_occurrences_profile_id '
  'ON task_occurrences (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_task_occurrences_key '
  'ON task_occurrences (profile_id, task_id, occurrence_key)',
)
@TableIndex(
  name: 'ix_task_occurrences_status',
  columns: {#profileId, #taskId, #status},
)
@TableIndex(
  name: 'ix_task_occurrences_due',
  columns: {#profileId, #occurrenceDueAtUtc},
)
class TaskOccurrences extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get taskId => text()();
  TextColumn get scheduleVersionId => text()();
  TextColumn get originalScheduleVersionId => text()();
  TextColumn get occurrenceKey => text()();
  TextColumn get status => text()();
  IntColumn get generatedVersion =>
      integer().withDefault(const Constant<int>(1))();
  IntColumn get occurrenceDueAtUtc => integer().nullable()();
  TextColumn get occurrenceTimezone => text().nullable()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'UNIQUE (profile_id, task_id, occurrence_key)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, task_id) REFERENCES tasks (profile_id, id)',
    ('FOREIGN KEY (profile_id, schedule_version_id) '
        'REFERENCES recurrence_rules (profile_id, id)'),
    ("CHECK (status IN "
        "('open', 'completed', 'skipped', 'overridden', 'cancelled'))"),
    'CHECK (generated_version >= 1)',
  ];
}

/// Append-only, immutable occurrence event log.
@DataClassName('TaskOccurrenceEventRow')
@TableIndex(
  name: 'ix_task_occurrence_events_occurrence_time',
  columns: {#profileId, #occurrenceId, #occurredAtUtc},
)
@TableIndex(
  name: 'ix_task_occurrence_events_command',
  columns: {#profileId, #commandId},
)
class TaskOccurrenceEvents extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get occurrenceId => text()();
  TextColumn get commandId => text().nullable()();
  TextColumn get eventKind => text()();
  TextColumn get payload => text().nullable()();
  IntColumn get payloadVersion => integer()();
  IntColumn get occurredAtUtc => integer()();
  TextColumn get supersedesId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    ('FOREIGN KEY (profile_id, occurrence_id) '
        'REFERENCES task_occurrences (profile_id, id)'),
    ("CHECK (event_kind IN "
        "('complete', 'exception', 'override', 'correct', 'undo', 'split'))"),
  ];
}
