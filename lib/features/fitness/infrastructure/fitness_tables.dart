import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// Fitness schema (data-model §3 "Planning, focus, fitness"; R-FIT-001,
// R-FIT-002, R-FIT-004, R-FIT-005, R-GEN-002).
// ---------------------------------------------------------------------------
//
// Ownership:
//   * `workout_templates`   direct-area owner `(profile_id, life_area_id)`.
//   * `template_exercises`  inherited via `(profile_id, template_id)`.
//   * `workout_sessions`    direct-area owner `(profile_id, life_area_id)`.
//   * `exercise_logs`       inherited via `(profile_id, workout_id)`.
//   * `set_logs`            inherited via `(profile_id, exercise_log_id)`.
//   * `body_measurements`   direct-area owner `(profile_id, life_area_id)`.
//   * `water_events`        direct-area owner `(profile_id, life_area_id)`.
//
// Unit preservation (R-FIT-002): weight/distance and body-weight columns store
// BOTH the exact entered value/unit AND a canonical integer amount (`*_scaled`,
// in the dimension's canonical base) for computation and cross-unit history.
// The entered value/unit is authoritative for display and never drifts through
// rounding, mirroring the habits duration/quantity unit-preservation pattern.
//
// Every table carries `profile_id` and a `revision` (where mutable) so the
// records are ownership-classified and sync-eligible for a later join (task
// 12.1); no sync wiring lives here.

/// A reusable workout template: a top-level direct-area owner (R-FIT-001).
@DataClassName('WorkoutTemplateRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_workout_templates_profile_id '
  'ON workout_templates (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_workout_templates_area_id '
  'ON workout_templates (profile_id, life_area_id, id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_workout_templates_active_rank '
  'ON workout_templates (profile_id, life_area_id, rank, id) '
  "WHERE deleted_at_utc IS NULL AND status = 'active'",
)
class WorkoutTemplates extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get lifeAreaId => text()();
  TextColumn get title => text()();
  TextColumn get rank => text()();
  TextColumn get status => text()();
  TextColumn get noteId => text().nullable()();
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

/// A planned exercise inside a template (R-FIT-001). Inherited-area child.
@DataClassName('TemplateExerciseRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_template_exercises_profile_id '
  'ON template_exercises (profile_id, id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_template_exercises_rank '
  'ON template_exercises (profile_id, template_id, rank, id)',
)
class TemplateExercises extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get templateId => text()();
  TextColumn get name => text()();
  TextColumn get rank => text()();
  IntColumn get targetSets => integer().nullable()();
  IntColumn get targetReps => integer().nullable()();
  TextColumn get notes => text().nullable()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    ('FOREIGN KEY (profile_id, template_id) '
        'REFERENCES workout_templates (profile_id, id)'),
    'CHECK (target_sets IS NULL OR target_sets > 0)',
    'CHECK (target_reps IS NULL OR target_reps > 0)',
  ];
}

/// A logged workout session: a top-level direct-area owner (R-FIT-001).
@DataClassName('WorkoutSessionRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_workout_sessions_profile_id '
  'ON workout_sessions (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_workout_sessions_area_id '
  'ON workout_sessions (profile_id, life_area_id, id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_workout_sessions_started '
  'ON workout_sessions (profile_id, started_at_utc, id) '
  'WHERE deleted_at_utc IS NULL',
)
@TableIndex(
  name: 'ix_workout_sessions_template',
  columns: {#profileId, #templateId},
)
class WorkoutSessions extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get lifeAreaId => text()();
  TextColumn get templateId => text().nullable()();
  TextColumn get title => text()();
  IntColumn get startedAtUtc => integer()();
  IntColumn get endedAtUtc => integer().nullable()();
  IntColumn get durationSec => integer().nullable()();
  TextColumn get noteId => text().nullable()();
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
    ('FOREIGN KEY (profile_id, template_id) '
        'REFERENCES workout_templates (profile_id, id)'),
    'CHECK (revision >= 1)',
    'CHECK (duration_sec IS NULL OR duration_sec >= 0)',
    'CHECK (ended_at_utc IS NULL OR ended_at_utc >= started_at_utc)',
  ];
}

/// A performed exercise within a session (R-FIT-001). Inherited-area child.
@DataClassName('ExerciseLogRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_exercise_logs_profile_id '
  'ON exercise_logs (profile_id, id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_exercise_logs_rank '
  'ON exercise_logs (profile_id, workout_id, rank, id)',
)
class ExerciseLogs extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get workoutId => text()();
  TextColumn get name => text()();
  TextColumn get rank => text()();
  TextColumn get notes => text().nullable()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    ('FOREIGN KEY (profile_id, workout_id) '
        'REFERENCES workout_sessions (profile_id, id)'),
  ];
}

/// A single performed set within an exercise log (R-FIT-001, R-FIT-002).
///
/// `weight`/`distance` preserve the entered value + unit and carry a canonical
/// integer amount (`*_scaled`) for computation. Each measured group is
/// all-or-nothing: a scaled value implies its entered value and unit.
@DataClassName('SetLogRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_set_logs_profile_id '
  'ON set_logs (profile_id, id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_set_logs_rank '
  'ON set_logs (profile_id, exercise_log_id, rank, id)',
)
class SetLogs extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get exerciseLogId => text()();
  TextColumn get rank => text()();
  IntColumn get reps => integer().nullable()();
  // Weight: canonical milligrams + preserved entered value/unit.
  IntColumn get weightScaled => integer().nullable()();
  RealColumn get weightEntered => real().nullable()();
  TextColumn get weightUnit => text().nullable()();
  // Duration in canonical seconds.
  IntColumn get durationSec => integer().nullable()();
  // Distance: canonical millimetres + preserved entered value/unit.
  IntColumn get distanceScaled => integer().nullable()();
  RealColumn get distanceEntered => real().nullable()();
  TextColumn get distanceUnit => text().nullable()();
  IntColumn get completedAtUtc => integer().nullable()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    ('FOREIGN KEY (profile_id, exercise_log_id) '
        'REFERENCES exercise_logs (profile_id, id)'),
    'CHECK (reps IS NULL OR reps >= 0)',
    'CHECK (duration_sec IS NULL OR duration_sec >= 0)',
    // Weight is all-or-nothing and non-negative when present (R-FIT-002).
    ('CHECK ((weight_scaled IS NULL AND weight_entered IS NULL '
        'AND weight_unit IS NULL) OR '
        '(weight_scaled IS NOT NULL AND weight_scaled >= 0 '
        'AND weight_entered IS NOT NULL AND weight_entered >= 0 '
        'AND weight_unit IS NOT NULL))'),
    // Distance is all-or-nothing and non-negative when present (R-FIT-002).
    ('CHECK ((distance_scaled IS NULL AND distance_entered IS NULL '
        'AND distance_unit IS NULL) OR '
        '(distance_scaled IS NOT NULL AND distance_scaled >= 0 '
        'AND distance_entered IS NOT NULL AND distance_entered >= 0 '
        'AND distance_unit IS NOT NULL))'),
  ];
}

/// A body-weight measurement: a direct-area owner (R-FIT-002, R-FIT-004).
///
/// `value_scaled` is the canonical amount (milligrams for weight);
/// `entered_value`/`entered_unit` preserve the exact value/unit as entered.
@DataClassName('BodyMeasurementRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_body_measurements_profile_id '
  'ON body_measurements (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_body_measurements_area_id '
  'ON body_measurements (profile_id, life_area_id, id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_body_measurements_kind_time '
  'ON body_measurements (profile_id, kind, measured_at_utc, id) '
  'WHERE deleted_at_utc IS NULL',
)
class BodyMeasurements extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get lifeAreaId => text()();
  TextColumn get kind => text()();
  IntColumn get valueScaled => integer()();
  RealColumn get enteredValue => real()();
  TextColumn get enteredUnit => text()();
  IntColumn get measuredAtUtc => integer()();
  TextColumn get note => text().nullable()();
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
    // V1 records only neutral body-weight (R-FIT-002, R-FIT-005).
    "CHECK (kind IN ('weight'))",
    'CHECK (value_scaled >= 0)',
    'CHECK (entered_value >= 0)',
    'CHECK (revision >= 1)',
  ];
}

/// An optional water-intake event: a direct-area owner (R-FIT-003).
///
/// Water tracking is optional and disabled by default; the disabled-by-default
/// choice is a local, non-sync preference in the `settings` table, so the table
/// simply stays empty until a person enables and logs water. `amount_scaled` is
/// the canonical amount (microlitres for volume); `entered_value`/`entered_unit`
/// preserve the exact value/unit as entered (ml/l/fl oz/...), mirroring the
/// body-weight unit-preservation pattern. No medical or coaching interpretation
/// is modelled (R-FIT-004, R-FIT-005).
@DataClassName('WaterEventRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_water_events_profile_id '
  'ON water_events (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_water_events_area_id '
  'ON water_events (profile_id, life_area_id, id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_water_events_profile_time '
  'ON water_events (profile_id, occurred_at_utc, id) '
  'WHERE deleted_at_utc IS NULL',
)
@TableIndex.sql(
  'CREATE INDEX idx_water_events_area_time '
  'ON water_events (profile_id, life_area_id, occurred_at_utc, id) '
  'WHERE deleted_at_utc IS NULL',
)
class WaterEvents extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get lifeAreaId => text()();
  IntColumn get amountScaled => integer()();
  RealColumn get enteredValue => real()();
  TextColumn get enteredUnit => text()();
  IntColumn get occurredAtUtc => integer()();
  TextColumn get note => text().nullable()();
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
    // A water amount is neutral and non-negative (R-FIT-003).
    'CHECK (amount_scaled >= 0)',
    'CHECK (entered_value >= 0)',
    'CHECK (revision >= 1)',
  ];
}
