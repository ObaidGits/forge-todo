import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// Tasks schema (data-model §3 "Tasks and reminders"; R-TASK-003, R-TASK-004,
// R-TASK-010).
// ---------------------------------------------------------------------------
//
// `tasks` is a direct-area owner: every task carries `(profile_id,
// life_area_id)` and references `life_areas(profile_id, id)`. A subtask
// additionally references its parent through the composite
// `(profile_id, life_area_id, parent_task_id)` foreign key, which forces a
// subtask into the same area as its parent (data-model §1). Notes are a
// canonical reference only — `note_id` never carries an inline body
// (R-TASK-010). Recurrence columns are populated by the recurrence engine
// (task 4.2) and are null for a non-recurring task.

/// Top-level and subtask tasks.
@DataClassName('TaskRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_tasks_profile_id ON tasks (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_tasks_area_id '
  'ON tasks (profile_id, life_area_id, id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_tasks_today '
  'ON tasks (profile_id, scheduled_date, due_date, priority, rank, id) '
  "WHERE deleted_at_utc IS NULL AND status IN ('open', 'in_progress')",
)
@TableIndex.sql(
  'CREATE INDEX idx_tasks_due_at '
  'ON tasks (profile_id, due_at_utc, id) '
  'WHERE deleted_at_utc IS NULL AND due_at_utc IS NOT NULL '
  "AND status IN ('open', 'in_progress')",
)
@TableIndex.sql(
  'CREATE INDEX idx_tasks_completed '
  'ON tasks (profile_id, completed_at_utc, id) '
  "WHERE deleted_at_utc IS NULL AND status = 'completed'",
)
@TableIndex(name: 'ix_tasks_parent', columns: {#profileId, #parentTaskId})
@TableIndex(
  name: 'ix_tasks_area_rank',
  columns: {#profileId, #lifeAreaId, #rank},
)
class Tasks extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get lifeAreaId => text()();
  TextColumn get parentTaskId => text().nullable()();
  TextColumn get title => text()();
  TextColumn get status => text()();
  TextColumn get priority => text()();
  TextColumn get scheduledDate => text().nullable()();
  TextColumn get dueDate => text().nullable()();
  IntColumn get dueAtUtc => integer().nullable()();
  TextColumn get dueTimezone => text().nullable()();
  IntColumn get estimateMinutes => integer().nullable()();
  TextColumn get recurrenceRuleId => text().nullable()();
  IntColumn get recurrenceVersion => integer().nullable()();
  IntColumn get completedAtUtc => integer().nullable()();
  TextColumn get noteId => text().nullable()();
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
    'FOREIGN KEY (profile_id, life_area_id, parent_task_id) REFERENCES tasks (profile_id, life_area_id, id)',
    "CHECK (status IN ('open', 'in_progress', 'completed', 'cancelled'))",
    "CHECK (priority IN ('none', 'low', 'medium', 'high', 'urgent'))",
    // due_date XOR due_at_utc: at most one due form (data-model §4).
    'CHECK (NOT (due_date IS NOT NULL AND due_at_utc IS NOT NULL))',
    // An instant due carries its display timezone; a non-instant due has none.
    'CHECK ((due_at_utc IS NULL AND due_timezone IS NULL) OR (due_at_utc IS NOT NULL AND due_timezone IS NOT NULL))',
    // A completed task has a completion instant; a non-terminal task does not.
    "CHECK ((status = 'completed' AND completed_at_utc IS NOT NULL) OR (status = 'cancelled') OR (status IN ('open', 'in_progress') AND completed_at_utc IS NULL))",
    'CHECK (estimate_minutes IS NULL OR estimate_minutes >= 0)',
    // A task cannot be its own parent.
    'CHECK (parent_task_id IS NULL OR parent_task_id <> id)',
  ];
}
