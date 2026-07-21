/// Normative ownership classification for every Forge table.
///
/// R-GEN-002 requires the data dictionary to classify every table as
/// direct-area, inherited-area, or area-free. data-model.md additionally
/// distinguishes the installation-root tables (`profiles`). Every generated
/// table MUST appear in [forgeTableOwnership]; schema CI fails otherwise.
library;

/// The four ownership classes defined by data-model.md.
enum OwnershipClass {
  /// Installation root: exactly one active local profile.
  installationRoot,

  /// Top-level classifiable aggregate carrying `(profile_id, life_area_id)`.
  directAreaOwner,

  /// Strictly owned child that inherits profile/area through a composite
  /// parent relationship.
  inheritedArea,

  /// Profile-owned operational, security, sync, or cross-cutting record that is
  /// legitimately area-free.
  areaFree,
}

/// Classification of every table introduced by the core schema (task 3.2).
///
/// Domain feature tables (tasks, goals, habits, ...) register their own
/// classification when their wave lands; the completeness test only asserts
/// that every table present in the database has exactly one class here.
const Map<String, OwnershipClass>
forgeTableOwnership = <String, OwnershipClass>{
  // Installation root.
  'profiles': OwnershipClass.installationRoot,

  // Tasks feature (Wave 3). A top-level task is a direct-area owner; a
  // subtask inherits its parent's area through the composite parent FK.
  'tasks': OwnershipClass.directAreaOwner,

  // Recurring-task series (Wave 3). Immutable schedule versions and
  // occurrence history inherit their Life Area from the owning task through
  // the composite `(profile_id, task_id)` foreign key.
  'recurrence_rules': OwnershipClass.inheritedArea,
  'task_occurrences': OwnershipClass.inheritedArea,
  'task_occurrence_events': OwnershipClass.inheritedArea,

  // Notifications feature (Wave 3). Reminders inherit their Life Area from
  // their polymorphic owner (validated by the owner registry) and are
  // profile-scoped; they carry no redundant area (data-model §3).
  'reminders': OwnershipClass.inheritedArea,

  // Search feature (Wave 4). The unified index content tables are
  // profile-owned, area-free, local-only projections.
  'fts_rowids': OwnershipClass.areaFree,
  'search_documents': OwnershipClass.areaFree,

  // Planner feature (Wave 4). A planning record is a top-level direct-area
  // owner; its entries, factual close event, close items, and close
  // adjustments inherit profile/area through composite parent keys
  // (R-PLAN-001..003, R-GEN-002; data-model §1).
  'planning_periods': OwnershipClass.directAreaOwner,
  'planning_entries': OwnershipClass.inheritedArea,
  'planning_close_events': OwnershipClass.inheritedArea,
  'planning_close_items': OwnershipClass.inheritedArea,
  'planning_close_adjustments': OwnershipClass.inheritedArea,

  // Notes feature (Wave 4). A note is a top-level direct-area owner; the
  // encrypted draft journal inherits its note's area through the composite
  // parent FK; the outgoing wiki-link set is profile-owned, area-free and
  // local-only (data-model §3).
  'notes': OwnershipClass.directAreaOwner,
  'note_drafts': OwnershipClass.inheritedArea,
  'note_links': OwnershipClass.areaFree,

  // Managed attachments (Wave 10, task 10.3). An attachment is a strictly-owned
  // child of a note that inherits profile/area through the composite
  // `(profile_id, note_id)` parent FK; its encrypted content lives outside
  // SQLite and is local-only (R-NOTE-006, R-SEC-002; data-model §1/§3).
  'attachments': OwnershipClass.inheritedArea,

  // Learning feature (Wave 5). A Learning Resource (internal `courses`) is a
  // top-level direct-area owner; its ordered items, append-only versioned
  // study sessions, and immutable study-session lifecycle events inherit
  // profile/area through composite parent keys (R-LEARN-001..005,
  // R-GEN-002; data-model §1/§3).
  'courses': OwnershipClass.directAreaOwner,
  'learning_items': OwnershipClass.inheritedArea,
  'study_sessions': OwnershipClass.inheritedArea,
  'study_session_events': OwnershipClass.inheritedArea,

  // Goals feature (Wave 6). A goal is a top-level direct-area owner; a
  // milestone is a strictly-owned child that inherits its Life Area from
  // the owning goal through the composite `(profile_id, goal_id)` parent FK
  // (R-GOAL-002, R-GOAL-007, R-GEN-002; data-model §1).
  'goals': OwnershipClass.directAreaOwner,
  'milestones': OwnershipClass.inheritedArea,

  // Roadmap feature (Wave 6, task 6.2). A roadmap details a single goal; its
  // sections, topics, and checklist items are strictly-owned children that
  // inherit profile/area through composite parent FKs down the chain
  // goal -> roadmap -> section -> topic -> checklist item (R-GOAL-003,
  // R-GOAL-004, R-GEN-002; data-model §1/§3).
  'roadmaps': OwnershipClass.inheritedArea,
  'roadmap_sections': OwnershipClass.inheritedArea,
  'roadmap_topics': OwnershipClass.inheritedArea,
  'checklist_items': OwnershipClass.inheritedArea,

  // Focus feature (Wave 6, task 7.3). A focus session is a top-level
  // direct-area owner; its projected work/pause intervals and append-only
  // lifecycle/correction events are strictly-owned children that inherit
  // profile/area through the composite `(profile_id, session_id)` parent FK
  // (R-FOCUS-001..006, R-GEN-002; data-model §1/§3).
  'focus_sessions': OwnershipClass.directAreaOwner,
  'focus_intervals': OwnershipClass.inheritedArea,
  'focus_events': OwnershipClass.inheritedArea,

  // Fitness feature (Wave 9, task 10.1). Workout templates and sessions and
  // body-weight measurements are top-level direct-area owners; template
  // exercises, exercise logs, and set logs are strictly-owned children that
  // inherit profile/area through composite parent FKs down the chain
  // template -> template_exercise and session -> exercise_log -> set_log
  // (R-FIT-001, R-FIT-002, R-GEN-002; data-model §1/§3).
  'workout_templates': OwnershipClass.directAreaOwner,
  'template_exercises': OwnershipClass.inheritedArea,
  'workout_sessions': OwnershipClass.directAreaOwner,
  'exercise_logs': OwnershipClass.inheritedArea,
  'set_logs': OwnershipClass.inheritedArea,
  'body_measurements': OwnershipClass.directAreaOwner,
  // Optional water tracking (Wave 9, task 10.2). A water event is a top-level
  // direct-area owner carrying `(profile_id, life_area_id)`; the disabled-by-
  // default toggle is a local `settings` row, not a table class (R-FIT-003,
  // R-GEN-002; data-model §1/§3).
  'water_events': OwnershipClass.directAreaOwner,

  // Habits feature (Wave 6, task 7.1). A habit is a top-level direct-area
  // owner; its immutable schedule/target versions, deterministic occurrences,
  // append-only versioned check-ins, and pause spans are strictly-owned
  // children that inherit profile/area through the composite
  // `(profile_id, habit_id)` / `(profile_id, occurrence_id)` parent FKs
  // (R-HABIT-001..007, R-GEN-002; data-model §1/§3).
  'habits': OwnershipClass.directAreaOwner,
  'habit_schedules': OwnershipClass.inheritedArea,
  'habit_occurrences': OwnershipClass.inheritedArea,
  'habit_checkins': OwnershipClass.inheritedArea,
  'habit_pauses': OwnershipClass.inheritedArea,

  // Profile-owned, area-free identity/taxonomy.
  'devices': OwnershipClass.areaFree,
  'life_areas': OwnershipClass.areaFree,
  'tags': OwnershipClass.areaFree,
  'entity_tags': OwnershipClass.areaFree,
  'entity_links': OwnershipClass.areaFree,
  'settings': OwnershipClass.areaFree,

  // Commit sequence, receipts, journal, activity, projections.
  'commit_log': OwnershipClass.areaFree,
  'command_receipts': OwnershipClass.areaFree,
  'pending_command_journal': OwnershipClass.areaFree,
  'activity_events': OwnershipClass.areaFree,
  'projection_dirty': OwnershipClass.areaFree,

  // Sync and replication.
  'outbox_mutations': OwnershipClass.areaFree,
  'sync_profile_links': OwnershipClass.areaFree,
  'replication_manifest': OwnershipClass.areaFree,
  'sync_cursors': OwnershipClass.areaFree,
  'sync_conflicts': OwnershipClass.areaFree,
  'applied_operations': OwnershipClass.areaFree,
  'aggregate_cache': OwnershipClass.areaFree,

  // Durable file-operation journal for managed encrypted files.
  'file_journal': OwnershipClass.areaFree,

  // Migration bookkeeping.
  'schema_metadata': OwnershipClass.areaFree,
};

/// Returns the ownership class for [tableName], or null when the table is not
/// classified. A null result is a schema-CI failure.
OwnershipClass? ownershipClassFor(String tableName) =>
    forgeTableOwnership[tableName];

/// Names of tables that are legitimately not profile-scoped.
///
/// These operational singletons/registries are database-global rather than
/// owned by a profile. Every other table MUST carry a `profile_id`.
const Set<String> profileExemptTables = <String>{
  'schema_metadata',
  'replication_manifest',
};
