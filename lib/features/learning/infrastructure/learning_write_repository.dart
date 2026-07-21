import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/learning/domain/learning_item.dart';
import 'package:forge/features/learning/domain/learning_resource.dart';
import 'package:forge/features/learning/domain/study_session.dart';
import 'package:forge/features/learning/infrastructure/learning_mapper.dart';

/// Transaction-scoped write access to the learning tables (R-LEARN-001..005).
///
/// Created per transaction by the unit of work and resolved from the session
/// repository set inside a command body (design.md §5). The shared [scope]
/// rejects any use after the owning transaction completes. Study-session
/// version rows and lifecycle events are append-only; only the `is_current`
/// projection flag of a prior version is flipped when a correction supersedes
/// it.
final class LearningWriteRepository {
  LearningWriteRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;

  // ---- courses / Learning Resources --------------------------------------

  Future<LearningResource?> findResource(
    String profileId,
    String resourceId,
  ) async {
    scope.ensureActive();
    final CourseRow? row =
        await (db.select(db.courses)..where(
              (Courses c) =>
                  c.profileId.equals(profileId) & c.id.equals(resourceId),
            ))
            .getSingleOrNull();
    return row == null ? null : LearningMapper.resourceFromRow(row);
  }

  Future<void> insertResource(LearningResource resource) async {
    scope.ensureActive();
    await db.into(db.courses).insert(LearningMapper.resourceToInsert(resource));
  }

  Future<void> updateResource(LearningResource resource) async {
    scope.ensureActive();
    await (db.update(db.courses)..where(
          (Courses c) =>
              c.profileId.equals(resource.profileId.value) &
              c.id.equals(resource.id.value),
        ))
        .write(LearningMapper.resourceToUpdate(resource));
  }

  Future<List<String>> activeResourceIds(String profileId) async {
    scope.ensureActive();
    final List<CourseRow> rows =
        await (db.select(db.courses)..where(
              (Courses c) =>
                  c.profileId.equals(profileId) & c.deletedAtUtc.isNull(),
            ))
            .get();
    return rows.map((CourseRow r) => r.id).toList(growable: false);
  }

  // ---- learning_items -----------------------------------------------------

  Future<LearningItem?> findItem(String profileId, String itemId) async {
    scope.ensureActive();
    final LearningItemRow? row =
        await (db.select(db.learningItems)..where(
              (LearningItems i) =>
                  i.profileId.equals(profileId) & i.id.equals(itemId),
            ))
            .getSingleOrNull();
    return row == null ? null : LearningMapper.itemFromRow(row);
  }

  Future<List<LearningItem>> itemsOf(String profileId, String courseId) async {
    scope.ensureActive();
    final List<LearningItemRow> rows =
        await (db.select(db.learningItems)
              ..where(
                (LearningItems i) =>
                    i.profileId.equals(profileId) & i.courseId.equals(courseId),
              )
              ..orderBy(<OrderClauseGenerator<LearningItems>>[
                (LearningItems i) => OrderingTerm.asc(i.rank),
                (LearningItems i) => OrderingTerm.asc(i.id),
              ]))
            .get();
    return rows.map(LearningMapper.itemFromRow).toList(growable: false);
  }

  Future<void> insertItem(LearningItem item) async {
    scope.ensureActive();
    await db.into(db.learningItems).insert(LearningMapper.itemToInsert(item));
  }

  Future<void> updateItem(LearningItem item) async {
    scope.ensureActive();
    await (db.update(db.learningItems)..where(
          (LearningItems i) =>
              i.profileId.equals(item.profileId) & i.id.equals(item.id),
        ))
        .write(LearningMapper.itemToUpdate(item));
  }

  /// The highest existing item rank in a resource, used to append at the end.
  Future<String?> lastItemRank(String profileId, String courseId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT rank FROM learning_items '
          'WHERE profile_id = ? AND course_id = ? '
          'ORDER BY rank DESC, id DESC LIMIT 1',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(courseId),
          ],
        )
        .get();
    return rows.isEmpty ? null : rows.single.data['rank'] as String;
  }

  // ---- study_sessions -----------------------------------------------------

  /// The current version row of a logical session, or null when none is
  /// current (e.g. an unknown logical id).
  Future<StudySession?> currentSession(
    String profileId,
    String logicalId,
  ) async {
    scope.ensureActive();
    final StudySessionRow? row =
        await (db.select(db.studySessions)..where(
              (StudySessions s) =>
                  s.profileId.equals(profileId) &
                  s.logicalId.equals(logicalId) &
                  s.isCurrent.equals(true),
            ))
            .getSingleOrNull();
    return row == null ? null : LearningMapper.sessionFromRow(row);
  }

  Future<void> insertSession(StudySession session) async {
    scope.ensureActive();
    await db
        .into(db.studySessions)
        .insert(LearningMapper.sessionToInsert(session));
  }

  /// Clears the `is_current` projection flag on a prior version row when a
  /// correction supersedes it. The row's immutable facts are untouched.
  Future<void> clearCurrent(String profileId, String sessionRowId) async {
    scope.ensureActive();
    await (db.update(db.studySessions)..where(
          (StudySessions s) =>
              s.profileId.equals(profileId) & s.id.equals(sessionRowId),
        ))
        .write(const StudySessionsCompanion(isCurrent: Value<bool>(false)));
  }

  Future<void> insertSessionEvent(StudySessionEvent event) async {
    scope.ensureActive();
    await db
        .into(db.studySessionEvents)
        .insert(LearningMapper.eventToInsert(event));
  }
}
