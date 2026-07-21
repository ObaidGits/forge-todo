import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// Roadmap schema (data-model.md §3 "Goals and roadmaps"; R-GOAL-001,
// R-GOAL-003, R-GOAL-004, R-GOAL-005).
// ---------------------------------------------------------------------------
//
// A roadmap details exactly one goal (R-GOAL-001): `roadmaps` carries the
// composite `(profile_id, goal_id)` parent FK and a unique index on that pair
// enforces "at most one roadmap per goal". Standalone roadmaps are not
// supported. Every roadmap table is a strictly-owned inherited-area child that
// derives its Life Area from the owning goal (data-model §1).
//
//   * `roadmaps`         inherited via `(profile_id, goal_id)`.
//   * `roadmap_sections` inherited via `(profile_id, roadmap_id)`; ordered by a
//                        stable fractional `rank`; NO completion weight
//                        (R-GOAL-004).
//   * `roadmap_topics`   inherited via `(profile_id, section_id)`; the ONLY
//                        weighted progress leaves; ordered by `rank`; carry a
//                        nonnegative nullable `weight`, estimate, status, note.
//   * `checklist_items`  inherited via `(profile_id, roadmap_topic_id)`;
//                        ordered by `rank`; never contribute to progress.
//
// Derived progress is never persisted as authoritative; it is recomputed from
// topics at read time (R-GOAL-004).

/// A goal's single roadmap (R-GOAL-001, R-GOAL-003).
@DataClassName('RoadmapRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_roadmaps_profile_id ON roadmaps (profile_id, id)',
)
@TableIndex.sql(
  // Enforces at most one roadmap per goal (R-GOAL-001).
  'CREATE UNIQUE INDEX ux_roadmaps_goal ON roadmaps (profile_id, goal_id)',
)
class Roadmaps extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get goalId => text()();
  TextColumn get title => text()();
  TextColumn get status => text()();
  TextColumn get targetDate => text().nullable()();
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
    // Inherited-area composite parent FK: a roadmap belongs to exactly one goal
    // under the same profile and derives its Life Area from it.
    'FOREIGN KEY (profile_id, goal_id) REFERENCES goals (profile_id, id)',
    "CHECK (status IN ('active', 'completed', 'archived'))",
    'CHECK (revision >= 1)',
  ];
}

/// Ordered roadmap sections. Sections have no completion weight (R-GOAL-004).
@DataClassName('RoadmapSectionRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_roadmap_sections_profile_id '
  'ON roadmap_sections (profile_id, id)',
)
@TableIndex(
  name: 'ix_roadmap_sections_rank',
  columns: {#profileId, #roadmapId, #rank},
)
class RoadmapSections extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get roadmapId => text()();
  TextColumn get title => text()();
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
    'FOREIGN KEY (profile_id, roadmap_id) REFERENCES roadmaps (profile_id, id)',
    'CHECK (revision >= 1)',
  ];
}

/// Ordered roadmap topics: the only weighted progress leaves (R-GOAL-003,
/// R-GOAL-004).
@DataClassName('RoadmapTopicRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_roadmap_topics_profile_id '
  'ON roadmap_topics (profile_id, id)',
)
@TableIndex(
  name: 'ix_roadmap_topics_rank',
  columns: {#profileId, #sectionId, #rank},
)
@TableIndex(name: 'ix_roadmap_topics_status', columns: {#profileId, #status})
class RoadmapTopics extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get sectionId => text()();
  TextColumn get title => text()();
  TextColumn get status => text()();

  /// Nonnegative nullable completion weight; null normalizes to 1 for progress
  /// (R-GOAL-004).
  RealColumn get weight => real().nullable()();
  IntColumn get estimateSec => integer().nullable()();
  TextColumn get noteId => text().nullable()();
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
    ('FOREIGN KEY (profile_id, section_id) '
        'REFERENCES roadmap_sections (profile_id, id)'),
    ("CHECK (status IN "
        "('open', 'in_progress', 'completed', 'archived', 'cancelled'))"),
    // Nonnegative completion weight (R-GOAL-004).
    'CHECK (weight IS NULL OR weight >= 0)',
    'CHECK (estimate_sec IS NULL OR estimate_sec >= 0)',
    'CHECK (revision >= 1)',
  ];
}

/// Ordered checklist items inside a topic. They never contribute to derived
/// progress (R-GOAL-004).
@DataClassName('ChecklistItemRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_checklist_items_profile_id '
  'ON checklist_items (profile_id, id)',
)
@TableIndex(
  name: 'ix_checklist_items_rank',
  columns: {#profileId, #roadmapTopicId, #rank},
)
class ChecklistItems extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get roadmapTopicId => text()();
  // The Dart getter avoids shadowing Table.text(); the SQL column stays `text`
  // per data-model §3.
  TextColumn get itemText => text().named('text')();
  IntColumn get checkedAtUtc => integer().nullable()();
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
    ('FOREIGN KEY (profile_id, roadmap_topic_id) '
        'REFERENCES roadmap_topics (profile_id, id)'),
    'CHECK (revision >= 1)',
  ];
}
