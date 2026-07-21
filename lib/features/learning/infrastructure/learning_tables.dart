import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// Learning schema (data-model §3 "Learning"; R-LEARN-001..005, R-FOCUS-005,
// R-GEN-002).
// ---------------------------------------------------------------------------
//
// The internal `course` table name is retained (R-LEARN-001) but is never a
// user-facing taxonomy — a Learning Resource has a `resource_type` of
// course/book/playlist/article/other.
//
// Ownership:
//   * `courses`               direct-area owner `(profile_id, life_area_id)`.
//   * `learning_items`         inherited via `(profile_id, course_id)`; a
//                              self-referencing `parent_id` groups items under
//                              a section within the same profile.
//   * `study_sessions`         inherited via `(profile_id, course_id)`; an
//                              append-only, versioned log — each correction
//                              inserts a superseding version row and the newest
//                              version carries `is_current = 1`.
//   * `study_session_events`   inherited via `(profile_id, session_id)`; the
//                              immutable lifecycle event log.

/// A Learning Resource (R-LEARN-001).
@DataClassName('CourseRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_courses_profile_id ON courses (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_courses_area_id '
  'ON courses (profile_id, life_area_id, id)',
)
@TableIndex.sql(
  'CREATE INDEX ix_courses_status '
  'ON courses (profile_id, status, updated_at_utc) '
  'WHERE deleted_at_utc IS NULL',
)
@TableIndex(
  name: 'ix_courses_area_rank',
  columns: {#profileId, #lifeAreaId, #rank},
)
class Courses extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get lifeAreaId => text()();
  TextColumn get title => text()();
  TextColumn get resourceType => text()();
  TextColumn get sourceUri => text().nullable()();
  TextColumn get creator => text().nullable()();
  TextColumn get status => text()();
  TextColumn get progressMode => text()();
  IntColumn get manualProgressPermille => integer().nullable()();
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
    "CHECK (resource_type IN ('course', 'book', 'playlist', 'article', 'other'))",
    "CHECK (status IN ('active', 'completed', 'on_hold', 'archived'))",
    "CHECK (progress_mode IN ('derived', 'manual'))",
    // Manual mode carries a clamped 0..1 value (stored per-mille); derived mode
    // never stores one (R-LEARN-004).
    ("CHECK ((progress_mode = 'manual' AND manual_progress_permille IS NOT NULL "
        'AND manual_progress_permille BETWEEN 0 AND 1000) '
        "OR (progress_mode = 'derived' AND manual_progress_permille IS NULL))"),
  ];
}

/// An ordered item inside a Learning Resource (R-LEARN-001, R-LEARN-004).
@DataClassName('LearningItemRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_learning_items_profile_id '
  'ON learning_items (profile_id, id)',
)
@TableIndex(
  name: 'ix_learning_items_course_rank',
  columns: {#profileId, #courseId, #rank},
)
@TableIndex(name: 'ix_learning_items_parent', columns: {#profileId, #parentId})
@TableIndex.sql(
  'CREATE INDEX ix_learning_items_incomplete '
  'ON learning_items (profile_id, course_id, rank) '
  'WHERE completed_at_utc IS NULL',
)
class LearningItems extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get courseId => text()();
  TextColumn get parentId => text().nullable()();
  TextColumn get title => text()();
  TextColumn get itemType => text()();
  TextColumn get sourceUri => text().nullable()();
  IntColumn get durationSec => integer().nullable()();
  IntColumn get completedAtUtc => integer().nullable()();
  TextColumn get rank => text()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, course_id) REFERENCES courses (profile_id, id)',
    'FOREIGN KEY (profile_id, parent_id) REFERENCES learning_items (profile_id, id)',
    ("CHECK (item_type IN "
        "('section', 'lesson', 'video', 'chapter', 'article', 'exercise', 'other'))"),
    'CHECK (duration_sec IS NULL OR duration_sec >= 0)',
    'CHECK (parent_id IS NULL OR parent_id <> id)',
  ];
}

/// An append-only, versioned study-session row (R-LEARN-002, R-FOCUS-005).
///
/// The partial unique index enforces exactly one current version per logical
/// session; corrections insert a superseding version and flip the prior row's
/// `is_current` projection flag without rewriting its immutable facts.
@DataClassName('StudySessionRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_study_sessions_profile_id '
  'ON study_sessions (profile_id, id)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_study_sessions_current '
  'ON study_sessions (profile_id, logical_id) WHERE is_current = 1',
)
@TableIndex(
  name: 'ix_study_sessions_start',
  columns: {#profileId, #startedAtUtc},
)
@TableIndex(
  name: 'ix_study_sessions_course_start',
  columns: {#profileId, #courseId, #startedAtUtc},
)
class StudySessions extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get courseId => text()();
  TextColumn get logicalId => text()();
  TextColumn get itemId => text().nullable()();
  TextColumn get focusSessionId => text().nullable()();
  IntColumn get startedAtUtc => integer()();
  IntColumn get endedAtUtc => integer()();
  IntColumn get durationSec => integer()();
  TextColumn get note => text().nullable()();
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
    'FOREIGN KEY (profile_id, course_id) REFERENCES courses (profile_id, id)',
    'FOREIGN KEY (profile_id, item_id) REFERENCES learning_items (profile_id, id)',
    'FOREIGN KEY (profile_id, supersedes_id) REFERENCES study_sessions (profile_id, id)',
    'CHECK (ended_at_utc >= started_at_utc)',
    'CHECK (duration_sec >= 0)',
    'CHECK (version >= 1)',
  ];
}

/// The immutable study-session lifecycle event log (R-LEARN-002).
@DataClassName('StudySessionEventRow')
@TableIndex(
  name: 'ix_study_session_events_time',
  columns: {#profileId, #logicalId, #occurredAtUtc},
)
@TableIndex(
  name: 'ix_study_session_events_command',
  columns: {#profileId, #commandId},
)
class StudySessionEvents extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get sessionId => text()();
  TextColumn get logicalId => text()();
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
    ('FOREIGN KEY (profile_id, session_id) '
        'REFERENCES study_sessions (profile_id, id)'),
    "CHECK (event_kind IN ('logged', 'corrected', 'undone'))",
  ];
}
