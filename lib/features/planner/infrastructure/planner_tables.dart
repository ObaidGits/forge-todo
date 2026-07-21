import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// Planner schema (data-model §3 "Planning, focus, fitness"; R-PLAN-001,
// R-PLAN-002, R-PLAN-003, R-PLAN-004, R-GEN-002).
// ---------------------------------------------------------------------------
//
// The planner is one record model, not separate planner entities. A single
// `planning_periods` row per (profile, life_area, kind, period_key) carries the
// named daily sections for a day record, or the plan/intention and reflection
// fields for a week/month record. CHECK constraints keep the non-applicable
// sections null.
//
// Ownership is inherited through composite parent keys and area-scoping:
//   * `planning_periods`          direct-area owner `(profile_id, life_area_id)`.
//   * `planning_entries`          inherited via `(profile_id, period_id)`.
//   * `planning_close_events`     inherited via `(profile_id, period_id)`;
//                                 exactly one immutable factual close per period.
//   * `planning_close_items`      inherited via `(profile_id, close_event_id)`.
//   * `planning_close_adjustments`inherited via `(profile_id, close_event_id)`;
//                                 append-only linked corrections/recomputations.

/// One area-scoped planning record (R-PLAN-001, R-PLAN-004).
@DataClassName('PlanningPeriodRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_planning_periods_profile_id '
  'ON planning_periods (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_planning_periods_key '
  'ON planning_periods (profile_id, life_area_id, kind, period_key)',
)
@TableIndex(
  name: 'ix_planning_periods_area',
  columns: {#profileId, #lifeAreaId, #kind},
)
class PlanningPeriods extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get lifeAreaId => text()();
  TextColumn get kind => text()();
  TextColumn get periodKey => text()();
  TextColumn get morningPlanMd => text().nullable()();
  TextColumn get dailyPlanMd => text().nullable()();
  TextColumn get eveningReflectionMd => text().nullable()();
  TextColumn get eveningPromptsJson => text().nullable()();
  TextColumn get planIntentionMd => text().nullable()();
  TextColumn get reflectionMd => text().nullable()();
  IntColumn get promptVersion =>
      integer().withDefault(const Constant<int>(1))();
  IntColumn get revision => integer().withDefault(const Constant<int>(1))();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();
  IntColumn get deletedAtUtc => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'UNIQUE (profile_id, life_area_id, kind, period_key)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, life_area_id) REFERENCES life_areas (profile_id, id)',
    "CHECK (kind IN ('day', 'week', 'month'))",
    'CHECK (prompt_version >= 1)',
    // A day record uses only the daily sections; a week/month record uses only
    // the aggregate sections. This keeps the one-record model coherent.
    ("CHECK (kind = 'day' OR (morning_plan_md IS NULL "
        'AND daily_plan_md IS NULL AND evening_reflection_md IS NULL '
        'AND evening_prompts_json IS NULL))'),
    ("CHECK (kind IN ('week', 'month') OR "
        '(plan_intention_md IS NULL AND reflection_md IS NULL))'),
  ];
}

/// A reference from a planning record to a task/goal/habit/note (R-PLAN-002,
/// R-PLAN-003). Plans reference entities rather than clone them.
@DataClassName('PlanningEntryRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_planning_entries_profile_id '
  'ON planning_entries (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_planning_entries_reference '
  'ON planning_entries (profile_id, period_id, entity_type, entity_id, role)',
)
@TableIndex(
  name: 'ix_planning_entries_period_rank',
  columns: {#profileId, #periodId, #role, #rank},
)
@TableIndex(
  name: 'ix_planning_entries_reverse',
  columns: {#profileId, #entityType, #entityId},
)
class PlanningEntries extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get periodId => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get role => text()();
  TextColumn get carriedFromEntryId => text().nullable()();
  TextColumn get rank => text()();
  TextColumn get addedEventId => text().nullable()();
  TextColumn get removedEventId => text().nullable()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, period_id) REFERENCES planning_periods (profile_id, id)',
    // A carry entry links to the source entry it was carried from; the composite
    // key keeps that link within the same profile.
    'FOREIGN KEY (profile_id, carried_from_entry_id) REFERENCES planning_entries (profile_id, id)',
    "CHECK (entity_type IN ('task', 'goal', 'habit', 'note'))",
    "CHECK (role IN ('planned', 'carry'))",
    // planned entries never carry a relation; carry entries always do.
    ("CHECK ((role = 'carry' AND carried_from_entry_id IS NOT NULL) "
        "OR (role = 'planned' AND carried_from_entry_id IS NULL))"),
  ];
}

/// The single immutable factual close snapshot of a planning period
/// (R-PLAN-003, R-HOME-004). The unique `(profile_id, period_id)` index makes
/// the "exactly one factual close per period" rule a database invariant.
@DataClassName('PlanningCloseEventRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_planning_close_events_profile_id '
  'ON planning_close_events (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_planning_close_events_period '
  'ON planning_close_events (profile_id, period_id)',
)
class PlanningCloseEvents extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get periodId => text()();
  IntColumn get closedAtUtc => integer()();
  IntColumn get boundaryUtc => integer()();
  IntColumn get metricPolicyVersion => integer()();
  IntColumn get sourceCommitSeq => integer()();
  IntColumn get eligibleCount => integer()();
  IntColumn get completedCount => integer()();
  IntColumn get missedCount => integer()();
  IntColumn get carriedCount => integer()();
  TextColumn get eligibleRootHash => text()();
  TextColumn get completedRootHash => text()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'UNIQUE (profile_id, period_id)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, period_id) REFERENCES planning_periods (profile_id, id)',
    'CHECK (eligible_count >= 0 AND completed_count >= 0 AND missed_count >= 0 AND carried_count >= 0)',
    'CHECK (completed_count <= eligible_count)',
    'CHECK (missed_count <= eligible_count)',
    // Carried is a labeled subset of missed, never double-counted.
    'CHECK (carried_count <= missed_count)',
    'CHECK (metric_policy_version >= 1)',
  ];
}

/// One item captured in a factual close (R-PLAN-003, R-HOME-004).
@DataClassName('PlanningCloseItemRow')
@TableIndex(
  name: 'ix_planning_close_items_reverse',
  columns: {#profileId, #entityType, #entityId},
)
class PlanningCloseItems extends Table {
  TextColumn get profileId => text()();
  TextColumn get closeEventId => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  BoolColumn get isPlanned => boolean().nullable()();
  BoolColumn get isDue => boolean().nullable()();
  TextColumn get taskDueDate => text().nullable()();
  TextColumn get status => text()();
  TextColumn get sourceEventId => text().nullable()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{
    profileId,
    closeEventId,
    entityType,
    entityId,
  };

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, close_event_id) REFERENCES planning_close_events (profile_id, id)',
    "CHECK (entity_type IN ('task', 'habit_occurrence'))",
  ];
}

/// A linked, append-only adjustment to an immutable factual close (R-PLAN-003,
/// R-HABIT-005). Source corrections and policy recomputations are appended;
/// the factual close is never rewritten.
@DataClassName('PlanningCloseAdjustmentRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_planning_close_adjustments_profile_id '
  'ON planning_close_adjustments (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_planning_close_adjustments_source '
  'ON planning_close_adjustments '
  '(profile_id, close_event_id, kind, affected_entity_type, '
  'affected_entity_id, affected_metric) '
  'WHERE affected_entity_id IS NOT NULL AND affected_metric IS NOT NULL',
)
@TableIndex(
  name: 'ix_planning_close_adjustments_time',
  columns: {#profileId, #closeEventId, #occurredAtUtc},
)
class PlanningCloseAdjustments extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get closeEventId => text()();
  TextColumn get kind => text()();
  TextColumn get sourceCommandId => text().nullable()();
  TextColumn get sourceEventId => text().nullable()();
  IntColumn get sourceCommitSeq => integer().nullable()();
  TextColumn get reason => text().nullable()();
  TextColumn get affectedEntityType => text().nullable()();
  TextColumn get affectedEntityId => text().nullable()();
  TextColumn get affectedMetric => text().nullable()();
  TextColumn get priorClassification => text().nullable()();
  TextColumn get currentClassification => text().nullable()();
  IntColumn get delta => integer().nullable()();
  IntColumn get metricPolicyVersion => integer()();
  TextColumn get derivedSummaryJson => text().nullable()();
  TextColumn get derivedRootHash => text().nullable()();
  IntColumn get occurredAtUtc => integer()();
  TextColumn get supersedesId => text().nullable()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, close_event_id) REFERENCES planning_close_events (profile_id, id)',
    "CHECK (kind IN ('source_correction', 'policy_recomputation'))",
    'CHECK (metric_policy_version >= 1)',
  ];
}
