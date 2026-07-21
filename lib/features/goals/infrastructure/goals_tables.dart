import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// Goals schema (data-model.md §3 "Goals and roadmaps"; R-GOAL-001, R-GOAL-002,
// R-GOAL-004, R-GOAL-007).
// ---------------------------------------------------------------------------
//
// `goals` is a direct-area owner: every goal carries `(profile_id,
// life_area_id)` and references `life_areas(profile_id, id)`. Notes are a
// canonical reference only — `note_id` never carries an inline body
// (R-GOAL-002). Progress is never persisted as authoritative: `progress_mode`
// and the clamped `manual_progress` are the only stored progress inputs, and
// derived progress is recomputed from roadmap topics (task 6.2) at read time
// (R-GOAL-004). Archival is `archived_at_utc`, orthogonal to `status`, and
// preserves all history and links (R-GOAL-007).
//
// `milestones` is a strictly-owned inherited-area child: it references its goal
// through the composite `(profile_id, goal_id)` parent key and derives its Life
// Area from that goal (data-model §1). Completion history is preserved through
// append-only `activity_events`; the row records only the current completion
// instant (R-GOAL-006).

/// Goals: unlimited per profile, no paid gating (R-GOAL-001).
@DataClassName('GoalRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_goals_profile_id ON goals (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_goals_area_id '
  'ON goals (profile_id, life_area_id, id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_goals_status '
  'ON goals (profile_id, status, target_date, id) '
  'WHERE deleted_at_utc IS NULL',
)
@TableIndex.sql(
  'CREATE INDEX idx_goals_active_rank '
  'ON goals (profile_id, life_area_id, rank, id) '
  'WHERE deleted_at_utc IS NULL AND archived_at_utc IS NULL',
)
class Goals extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get lifeAreaId => text()();
  TextColumn get title => text()();
  TextColumn get outcomeMd => text().withDefault(const Constant<String>(''))();
  TextColumn get status => text()();
  TextColumn get targetDate => text().nullable()();
  TextColumn get progressMode => text()();
  RealColumn get manualProgress => real().nullable()();
  TextColumn get noteId => text().nullable()();
  IntColumn get archivedAtUtc => integer().nullable()();
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
    "CHECK (status IN ('active', 'on_hold', 'achieved', 'abandoned'))",
    "CHECK (progress_mode IN ('manual', 'derived'))",
    // Manual mode stores a clamped 0..1 value; derived mode stores none
    // (R-GOAL-004).
    ("CHECK ((progress_mode = 'manual' AND manual_progress IS NOT NULL "
        'AND manual_progress >= 0 AND manual_progress <= 1) '
        "OR (progress_mode = 'derived' AND manual_progress IS NULL))"),
    'CHECK (revision >= 1)',
  ];
}

/// Milestones: inherited-area children of a goal (R-GOAL-002, R-GOAL-006).
@DataClassName('MilestoneRow')
@TableIndex(
  name: 'ix_milestones_goal_rank',
  columns: {#profileId, #goalId, #rank},
)
@TableIndex(name: 'ix_milestones_target', columns: {#profileId, #targetDate})
class Milestones extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get goalId => text()();
  TextColumn get title => text()();
  TextColumn get targetDate => text().nullable()();
  IntColumn get completedAtUtc => integer().nullable()();
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
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    // Inherited-area composite parent FK: a milestone belongs to exactly one
    // goal under the same profile and derives its Life Area from it.
    'FOREIGN KEY (profile_id, goal_id) REFERENCES goals (profile_id, id)',
    'CHECK (revision >= 1)',
  ];
}
