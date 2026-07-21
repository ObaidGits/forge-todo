import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// Habits schema (data-model §3 "Habits"; R-HABIT-001..007, R-GEN-002).
// ---------------------------------------------------------------------------
//
// Ownership:
//   * `habits`             direct-area owner `(profile_id, life_area_id)`.
//   * `habit_schedules`    inherited via `(profile_id, habit_id)`; an immutable
//                          schedule + target version chain.
//   * `habit_occurrences`  inherited via `(profile_id, habit_id)`; the current
//                          status projection per deterministic occurrence key.
//   * `habit_checkins`     inherited via `(profile_id, occurrence_id)`; the
//                          append-only, versioned observation log — each
//                          correction inserts a superseding record and the
//                          newest carries `is_current = 1`.
//   * `habit_pauses`       inherited via `(profile_id, habit_id)`; pause spans.
//
// A habit schedule version stores its own timezone, effective range/rule
// version and target configuration; for every aggregate schedule that version's
// `target_value` under its target kind is the sole authoritative target — no
// duplicate `weekly_count` target column exists (R-HABIT-001).

/// A habit: unlimited per profile, a direct-area owner (R-HABIT-001, R-GEN-002).
@DataClassName('HabitRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_habits_profile_id ON habits (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_habits_area_id '
  'ON habits (profile_id, life_area_id, id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_habits_active_rank '
  'ON habits (profile_id, life_area_id, rank, id) '
  "WHERE deleted_at_utc IS NULL AND status = 'active'",
)
class Habits extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get lifeAreaId => text()();
  TextColumn get title => text()();
  TextColumn get currentScheduleVersionId => text()();
  TextColumn get status => text()();
  IntColumn get pausedAtUtc => integer().nullable()();
  TextColumn get rank => text()();
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
    "CHECK (status IN ('active', 'archived'))",
    'CHECK (revision >= 1)',
  ];
}

/// An immutable habit schedule + target version (R-HABIT-001, R-HABIT-002,
/// R-HABIT-003).
@DataClassName('HabitScheduleRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_habit_schedules_profile_id '
  'ON habit_schedules (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_habit_schedules_habit_version '
  'ON habit_schedules (profile_id, habit_id, version)',
)
@TableIndex(
  name: 'ix_habit_schedules_effective',
  columns: {#profileId, #habitId, #effectiveOccurrenceKey},
)
class HabitSchedules extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get habitId => text()();
  IntColumn get version => integer()();
  TextColumn get predecessorId => text().nullable()();
  TextColumn get effectiveOccurrenceKey => text()();
  TextColumn get closedAtOccurrenceKey => text().nullable()();
  TextColumn get frequency => text()();
  TextColumn get scheduleKind => text()();
  IntColumn get interval => integer().withDefault(const Constant<int>(1))();
  TextColumn get weekdays => text().nullable()();
  TextColumn get monthDays => text().nullable()();
  IntColumn get weekStart => integer().withDefault(const Constant<int>(1))();
  TextColumn get timezoneId => text()();
  TextColumn get startDate => text()();
  TextColumn get targetKind => text()();
  IntColumn get targetValue => integer().nullable()();
  TextColumn get unit => text().nullable()();
  TextColumn get displayUnit => text().nullable()();
  IntColumn get ruleVersion => integer().withDefault(const Constant<int>(1))();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, habit_id) REFERENCES habits (profile_id, id)',
    "CHECK (frequency IN ('daily', 'weekly', 'monthly'))",
    "CHECK (schedule_kind IN ('dated', 'aggregate'))",
    'CHECK ("interval" >= 1)',
    'CHECK (version >= 1)',
    'CHECK (rule_version >= 1)',
    'CHECK (week_start BETWEEN 1 AND 7)',
    // Aggregate periods are weekly/monthly only.
    "CHECK (schedule_kind = 'dated' OR frequency IN ('weekly', 'monthly'))",
    // Authoritative per-kind target invariants (R-HABIT-002). boolean and
    // abstinence carry no target/unit; count is a positive integer with no
    // unit; duration is positive canonical seconds preserving a display unit;
    // quantity is a positive target requiring a unit. There is no duplicate
    // aggregate target column.
    ("CHECK ("
        "(target_kind IN ('boolean', 'abstinence') AND target_value IS NULL "
        'AND unit IS NULL AND display_unit IS NULL) '
        "OR (target_kind = 'count' AND target_value IS NOT NULL "
        'AND target_value > 0 AND unit IS NULL AND display_unit IS NULL) '
        "OR (target_kind = 'duration' AND target_value IS NOT NULL "
        'AND target_value > 0 AND unit IS NULL AND display_unit IS NOT NULL) '
        "OR (target_kind = 'quantity' AND target_value IS NOT NULL "
        'AND target_value > 0 AND unit IS NOT NULL AND display_unit IS NULL))'),
  ];
}

/// The current status projection of one deterministic occurrence key
/// (R-HABIT-003, R-HABIT-004).
@DataClassName('HabitOccurrenceRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_habit_occurrences_profile_id '
  'ON habit_occurrences (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_habit_occurrences_key '
  'ON habit_occurrences (profile_id, habit_id, occurrence_key)',
)
@TableIndex(
  name: 'ix_habit_occurrences_status',
  columns: {#profileId, #habitId, #status},
)
@TableIndex(
  name: 'ix_habit_occurrences_anchor',
  columns: {#profileId, #habitId, #anchorDate},
)
class HabitOccurrences extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get habitId => text()();
  TextColumn get scheduleVersionId => text()();
  TextColumn get occurrenceKey => text()();
  TextColumn get anchorDate => text()();
  TextColumn get status => text()();
  IntColumn get normalizedTotal =>
      integer().withDefault(const Constant<int>(0))();
  BoolColumn get isPaused =>
      boolean().withDefault(const Constant<bool>(false))();
  IntColumn get closedAtUtc => integer().nullable()();
  IntColumn get sourceCommitSeq => integer().nullable()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'UNIQUE (profile_id, habit_id, occurrence_key)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, habit_id) REFERENCES habits (profile_id, id)',
    ('FOREIGN KEY (profile_id, schedule_version_id) '
        'REFERENCES habit_schedules (profile_id, id)'),
    "CHECK (status IN ('open', 'completed', 'missed', 'skipped'))",
    'CHECK (normalized_total >= 0)',
  ];
}

/// The append-only, versioned check-in observation log (R-HABIT-003,
/// R-HABIT-005).
///
/// The partial unique index enforces exactly one current record per logical
/// observation; a correction inserts a superseding record and flips the prior
/// record's `is_current` flag without rewriting its immutable facts.
@DataClassName('HabitCheckinRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_habit_checkins_profile_id '
  'ON habit_checkins (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_habit_checkins_current '
  'ON habit_checkins (profile_id, logical_id) WHERE is_current = 1',
)
@TableIndex(
  name: 'ix_habit_checkins_occurrence_time',
  columns: {#profileId, #occurrenceId, #recordedAtUtc},
)
class HabitCheckins extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get habitId => text()();
  TextColumn get occurrenceId => text()();
  TextColumn get logicalId => text()();
  TextColumn get eventKind => text()();
  RealColumn get rawValue => real().nullable()();
  TextColumn get rawUnit => text().nullable()();
  IntColumn get normalizedValue => integer().nullable()();
  TextColumn get note => text().nullable()();
  IntColumn get recordedAtUtc => integer()();
  IntColumn get version => integer()();
  TextColumn get supersedesId => text().nullable()();
  BoolColumn get isCurrent => boolean()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, habit_id) REFERENCES habits (profile_id, id)',
    ('FOREIGN KEY (profile_id, occurrence_id) '
        'REFERENCES habit_occurrences (profile_id, id)'),
    ('FOREIGN KEY (profile_id, supersedes_id) '
        'REFERENCES habit_checkins (profile_id, id)'),
    "CHECK (event_kind IN ('true', 'value', 'violation', 'correct'))",
    // Observations and their normalized amounts are never negative
    // (R-HABIT-003).
    'CHECK (raw_value IS NULL OR raw_value >= 0)',
    'CHECK (normalized_value IS NULL OR normalized_value >= 0)',
    'CHECK (version >= 1)',
  ];
}

/// A pause span for a habit (R-HABIT-004, R-HABIT-005). Occurrences whose
/// anchor falls in a pause span are ineligible for streak and consistency.
@DataClassName('HabitPauseRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_habit_pauses_profile_id '
  'ON habit_pauses (profile_id, id)',
)
@TableIndex(
  name: 'ix_habit_pauses_habit_date',
  columns: {#profileId, #habitId, #startDate},
)
class HabitPauses extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get habitId => text()();
  TextColumn get startDate => text()();
  TextColumn get endDate => text().nullable()();
  TextColumn get reason => text().nullable()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, habit_id) REFERENCES habits (profile_id, id)',
    'CHECK (end_date IS NULL OR end_date >= start_date)',
  ];
}
