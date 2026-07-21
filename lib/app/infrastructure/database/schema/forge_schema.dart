import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema_tables.dart';
import 'package:forge/features/fitness/infrastructure/fitness_tables.dart';
import 'package:forge/features/focus/infrastructure/focus_tables.dart';
import 'package:forge/features/goals/infrastructure/goals_tables.dart';
import 'package:forge/features/goals/infrastructure/roadmap_tables.dart';
import 'package:forge/features/habits/infrastructure/habits_tables.dart';
import 'package:forge/features/learning/infrastructure/learning_tables.dart';
import 'package:forge/features/notes/infrastructure/attachments_table.dart';
import 'package:forge/features/notes/infrastructure/notes_tables.dart';
import 'package:forge/features/notifications/infrastructure/reminders_table.dart';
import 'package:forge/features/planner/infrastructure/planner_tables.dart';
import 'package:forge/features/search/infrastructure/search_fts.dart';
import 'package:forge/features/search/infrastructure/search_tables.dart';
import 'package:forge/features/tasks/infrastructure/recurrence_tables.dart';
import 'package:forge/features/tasks/infrastructure/tasks_table.dart';

export 'package:forge/app/infrastructure/database/schema/forge_schema_tables.dart';
export 'package:forge/features/fitness/infrastructure/fitness_tables.dart';
export 'package:forge/features/focus/infrastructure/focus_tables.dart';
export 'package:forge/features/goals/infrastructure/goals_tables.dart';
export 'package:forge/features/goals/infrastructure/roadmap_tables.dart';
export 'package:forge/features/habits/infrastructure/habits_tables.dart';
export 'package:forge/features/learning/infrastructure/learning_tables.dart';
export 'package:forge/features/notes/infrastructure/attachments_table.dart';
export 'package:forge/features/notes/infrastructure/notes_tables.dart';
export 'package:forge/features/notifications/infrastructure/reminders_table.dart';
export 'package:forge/features/planner/infrastructure/planner_tables.dart';
export 'package:forge/features/search/infrastructure/search_tables.dart';
export 'package:forge/features/tasks/infrastructure/recurrence_tables.dart';
export 'package:forge/features/tasks/infrastructure/tasks_table.dart';

part 'forge_schema.g.dart';

/// The Forge core-schema database.
///
/// The declarative table definitions live in `forge_schema_tables.dart`; they
/// are DSL consumed by the drift code generator and are re-exported here for
/// convenience. This file owns the runtime database class.
///
/// The database lives behind the infrastructure boundary (`EncryptedStore`).
/// The concrete encrypted opener is deferred pending ADR-0001; the schema is
/// opened on any [QueryExecutor] — an in-memory native database in tests, and
/// an encrypted executor in production once the provider is accepted.
@DriftDatabase(
  tables: <Type>[
    Profiles,
    Devices,
    LifeAreas,
    Tags,
    EntityTags,
    EntityLinks,
    Settings,
    CommitLog,
    CommandReceipts,
    PendingCommandJournal,
    ActivityEvents,
    ProjectionDirty,
    OutboxMutations,
    SyncProfileLinks,
    ReplicationManifest,
    SyncCursors,
    SyncConflicts,
    AppliedOperations,
    AggregateCache,
    FileJournal,
    SchemaMetadata,
    // Feature-owned domain tables share the one database for transactions;
    // ownership is enforced by the feature repositories (design.md §4).
    Tasks,
    // Recurring-task series: immutable schedule versions plus append-only
    // occurrence history (R-TASK-005, R-TASK-006, R-TASK-007).
    RecurrenceRules,
    TaskOccurrences,
    TaskOccurrenceEvents,
    // Unified search index content tables (the FTS5 virtual table is created by
    // DDL in onCreate because Drift has no virtual-table DSL).
    FtsRowids,
    SearchDocuments,
    // Unified MVP reminder model shared by every aggregate type
    // (R-NOTIFY-001; polymorphic owner validated by the owner registry).
    Reminders,
    // Canonical Markdown notes, the encrypted draft journal, and the outgoing
    // wiki-link set (R-NOTE-001..005). Additive at schema v3.
    Notes,
    NoteDrafts,
    NoteLinks,
    // Managed encrypted attachments: an inherited-area child of a note whose
    // encrypted content lives outside SQLite under a generated path token with
    // a wrapped per-file DEK (R-NOTE-006, R-SEC-002). Additive at schema v11.
    Attachments,
    // Area-scoped planning records: one record per (profile, area, kind,
    // period_key) with named daily sections, references, and the single
    // immutable factual close plus append-only adjustments (R-PLAN-001..004).
    // Additive at schema v4.
    PlanningPeriods,
    PlanningEntries,
    PlanningCloseEvents,
    PlanningCloseItems,
    PlanningCloseAdjustments,
    // Goals feature (Wave 6). A goal is a top-level direct-area owner with an
    // optional roadmap (schema task 6.2), milestones, canonical note reference,
    // tags, and a manual/derived progress strategy (R-GOAL-001, R-GOAL-002,
    // R-GOAL-004, R-GOAL-007). Milestones are inherited-area children.
    Goals,
    Milestones,
    // Roadmap feature (Wave 6, task 6.2). A roadmap details a single goal and
    // owns ordered sections; sections own ordered topics; topics own checklist
    // items. Topics are the only weighted derived-progress leaves (R-GOAL-003,
    // R-GOAL-004, R-GOAL-005). All four are inherited-area children.
    Roadmaps,
    RoadmapSections,
    RoadmapTopics,
    ChecklistItems,
    // Learning feature (Wave 5). A Learning Resource (internal `courses`) is a
    // top-level direct-area owner; its ordered items, append-only versioned
    // study sessions, and immutable study-session lifecycle events are
    // inherited-area children (R-LEARN-001..005, R-FOCUS-005). Additive at
    // schema v7.
    Courses,
    LearningItems,
    StudySessions,
    StudySessionEvents,
    // Habits feature (Wave 6, task 7.1). A habit is a top-level direct-area
    // owner defined by a chain of immutable schedule/target versions; its
    // deterministic occurrences, append-only versioned check-ins, and pause
    // spans are inherited-area children (R-HABIT-001..007). Additive at schema
    // v9.
    Habits,
    HabitSchedules,
    HabitOccurrences,
    HabitCheckins,
    HabitPauses,
    // Focus feature (Wave 6, task 7.3). A focus session is a top-level
    // direct-area owner carrying anchored timer truth (wall + monotonic
    // anchors, boot id, accumulated duration) and a visible status projection;
    // its projected work/pause intervals and append-only lifecycle/correction
    // events are inherited-area children (R-FOCUS-001..006). Additive at
    // schema v10.
    FocusSessions,
    FocusIntervals,
    FocusEvents,
    // Fitness feature (Wave 9, task 10.1). Workout templates and sessions and
    // body-weight measurements are top-level direct-area owners; their
    // exercises, sets, and template exercises are inherited-area children.
    // Weight/distance/body-weight columns preserve the entered value/unit and
    // carry a canonical amount for computation (R-FIT-001, R-FIT-002,
    // R-FIT-004, R-FIT-005). Additive at schema v12.
    WorkoutTemplates,
    TemplateExercises,
    WorkoutSessions,
    ExerciseLogs,
    SetLogs,
    BodyMeasurements,
    // Optional water tracking (Wave 9, task 10.2). A water event is a
    // top-level direct-area owner; it preserves the entered value/unit
    // (ml/l/fl oz/...) and carries a canonical microlitre amount. Water
    // tracking is optional and disabled by default; the toggle is a local
    // non-sync `settings` row (R-FIT-003). Additive at schema v13.
    WaterEvents,
  ],
)
class ForgeSchemaDatabase extends _$ForgeSchemaDatabase {
  ForgeSchemaDatabase(super.executor);

  /// The current core schema version. Increments monotonically; every released
  /// encrypted schema snapshot is immutable and checksum-pinned (data-model §5).
  ///
  /// v2 adds the additive `reminders` table (task 4.5, R-NOTIFY-001). v3 adds
  /// the additive `notes`, `note_drafts` and `note_links` tables (task 5.1,
  /// R-NOTE-001..005). v4 adds the additive planner tables (`planning_periods`,
  /// `planning_entries`, `planning_close_events`, `planning_close_items`,
  /// `planning_close_adjustments`) (task 5.4, R-PLAN-001..004). v5 adds the
  /// additive `note_links.resolution` column so ambiguous/unresolved wiki-links
  /// are modelled explicitly (task 5.2, R-NOTE-003). v6 adds the additive
  /// `goals` and `milestones` tables (task 6.1, R-GOAL-001, R-GOAL-002,
  /// R-GOAL-004, R-GOAL-007). v7 adds the additive learning tables (`courses`,
  /// `learning_items`, `study_sessions`, `study_session_events`) (task 6.4,
  /// R-LEARN-001..005, R-FOCUS-005). v8 adds the additive roadmap tables
  /// (`roadmaps`, `roadmap_sections`, `roadmap_topics`, `checklist_items`)
  /// (task 6.2, R-GOAL-003, R-GOAL-004, R-GOAL-005). v9 adds the additive habit
  /// tables (`habits`, `habit_schedules`, `habit_occurrences`,
  /// `habit_checkins`, `habit_pauses`) (task 7.1, R-HABIT-001..007). v10 adds
  /// the additive focus tables (`focus_sessions`, `focus_intervals`,
  /// `focus_events`) (task 7.3, R-FOCUS-001..006). v11 adds the additive
  /// `attachments` table for managed encrypted attachments (task 10.3,
  /// R-NOTE-006, R-SEC-002). v12 adds the additive fitness tables
  /// (`workout_templates`, `template_exercises`, `workout_sessions`,
  /// `exercise_logs`, `set_logs`, `body_measurements`) (task 10.1, R-FIT-001,
  /// R-FIT-002, R-FIT-004, R-FIT-005). Every change is purely additive: fresh
  /// stores create the tables/columns in `onCreate`; an existing store gains
  /// them transactionally in `onUpgrade`.
  /// v13 adds the additive `water_events` table for optional,
  /// disabled-by-default water tracking (task 10.2, R-FIT-003). v14 widens the
  /// `reminders` owner_type/category CHECK constraints to admit the `workout`
  /// owner so V1 workout reminders share the one reminder model (task 10.5,
  /// R-NOTIFY-001); the reminders table is recreated in place preserving every
  /// existing row.
  @override
  int get schemaVersion => 14;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
      // The FTS5 external-content search index is a virtual table over
      // `search_documents` (design.md §14); create it after its content table.
      await SearchFts.create(this);
    },
    onUpgrade: (Migrator m, int from, int to) async {
      // Additive-only migration path (data-model §5.3). Each step creates the
      // tables introduced at that version; no existing row is rewritten.
      if (from < 2) {
        await m.createTable(reminders);
      }
      if (from < 3) {
        await m.createTable(notes);
        await m.createTable(noteDrafts);
        await m.createTable(noteLinks);
      }
      if (from < 4) {
        await m.createTable(planningPeriods);
        await m.createTable(planningEntries);
        await m.createTable(planningCloseEvents);
        await m.createTable(planningCloseItems);
        await m.createTable(planningCloseAdjustments);
      }
      if (from >= 3 && from < 5) {
        // Additive column for explicit wiki-link resolution state
        // (task 5.2, R-NOTE-003). Existing rows default to `unresolved`;
        // rows that already carry a resolved target are backfilled so the
        // `resolution`/`target_note_id` invariant holds before any read.
        //
        // Guarded on `from >= 3`: when upgrading from a pre-notes baseline
        // (v1/v2) the `from < 3` block above creates `note_links` from the
        // CURRENT table definition, which already includes `resolution`.
        // Running addColumn there would raise "duplicate column name" and abort
        // the whole additive migration, so the column is added only for the
        // v3/v4 baselines that genuinely predate it (NFR-MAIN-004).
        await m.addColumn(noteLinks, noteLinks.resolution);
        await customStatement(
          "UPDATE note_links SET resolution = 'resolved' "
          'WHERE target_note_id IS NOT NULL',
        );
      }
      if (from < 6) {
        // Additive goals + milestones tables (task 6.1, R-GOAL-001..007).
        await m.createTable(goals);
        await m.createTable(milestones);
      }
      if (from < 7) {
        // Additive learning tables (task 6.4, R-LEARN-001..005, R-FOCUS-005).
        await m.createTable(courses);
        await m.createTable(learningItems);
        await m.createTable(studySessions);
        await m.createTable(studySessionEvents);
      }
      if (from < 8) {
        // Additive roadmap tables (task 6.2, R-GOAL-003, R-GOAL-004,
        // R-GOAL-005).
        await m.createTable(roadmaps);
        await m.createTable(roadmapSections);
        await m.createTable(roadmapTopics);
        await m.createTable(checklistItems);
      }
      if (from < 9) {
        // Additive habit tables (task 7.1, R-HABIT-001..007).
        await m.createTable(habits);
        await m.createTable(habitSchedules);
        await m.createTable(habitOccurrences);
        await m.createTable(habitCheckins);
        await m.createTable(habitPauses);
      }
      if (from < 10) {
        // Additive focus tables (task 7.3, R-FOCUS-001..006).
        await m.createTable(focusSessions);
        await m.createTable(focusIntervals);
        await m.createTable(focusEvents);
      }
      if (from < 11) {
        // Additive managed-attachments table (task 10.3, R-NOTE-006,
        // R-SEC-002).
        await m.createTable(attachments);
      }
      if (from < 12) {
        // Additive fitness tables (task 10.1, R-FIT-001, R-FIT-002,
        // R-FIT-004, R-FIT-005).
        await m.createTable(workoutTemplates);
        await m.createTable(templateExercises);
        await m.createTable(workoutSessions);
        await m.createTable(exerciseLogs);
        await m.createTable(setLogs);
        await m.createTable(bodyMeasurements);
      }
      if (from < 13) {
        // Additive optional water-tracking table (task 10.2, R-FIT-003).
        await m.createTable(waterEvents);
      }
      if (from < 14) {
        // Widen the reminders owner_type/category CHECK constraints to admit
        // the `workout` owner (task 10.5, R-NOTIFY-001). SQLite cannot ALTER a
        // CHECK in place, so the table is recreated from its current Dart
        // definition and every existing row is copied verbatim; the column set
        // is unchanged, so no value is transformed and no reminder is lost.
        await m.alterTable(TableMigration(reminders));
      }
    },
    beforeOpen: (OpeningDetails details) async {
      // Foreign keys are enabled (data-model §1). Enforce before any read.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
