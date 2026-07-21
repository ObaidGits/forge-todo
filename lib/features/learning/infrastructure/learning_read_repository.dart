import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/time_span.dart';
import 'package:forge/features/learning/application/learning_duration_contract.dart';
import 'package:forge/features/learning/application/learning_resume_contract.dart';
import 'package:forge/features/learning/domain/learning_item.dart';
import 'package:forge/features/learning/domain/learning_policies.dart';
import 'package:forge/features/learning/domain/learning_repository.dart';
import 'package:forge/features/learning/domain/learning_resource.dart';
import 'package:forge/features/learning/domain/learning_resource_status.dart';
import 'package:forge/features/learning/domain/learning_statistics.dart';
import 'package:forge/features/learning/domain/study_session.dart';
import 'package:forge/features/learning/infrastructure/learning_mapper.dart';

/// Read-side learning repository over the active Drift generation.
///
/// Query methods run outside a write transaction and return immutable domain
/// aggregates (design.md §5 "Queries"). It also implements the study-side
/// [StudyDurationContract] so combined focus/study metrics can union intervals
/// without double counting (R-FOCUS-005), and the [LearningResumeContract] so
/// Home can surface a Today study recommendation without mutating it
/// (R-HOME-001, R-LEARN-003).
final class LearningReadRepository
    implements
        LearningRepository,
        StudyDurationContract,
        LearningResumeContract {
  LearningReadRepository(this._db);

  final ForgeSchemaDatabase _db;

  @override
  Future<List<LearningResource>> listResources(ProfileId profileId) async {
    final List<CourseRow> rows =
        await (_db.select(_db.courses)
              ..where(
                (Courses c) =>
                    c.profileId.equals(profileId.value) &
                    c.deletedAtUtc.isNull(),
              )
              ..orderBy(<OrderClauseGenerator<Courses>>[
                (Courses c) => OrderingTerm.desc(c.updatedAtUtc),
                (Courses c) => OrderingTerm.desc(c.id),
              ]))
            .get();
    return rows.map(LearningMapper.resourceFromRow).toList(growable: false);
  }

  @override
  Future<LearningResource?> findResource(
    ProfileId profileId,
    LearningResourceId resourceId,
  ) async {
    final CourseRow? row =
        await (_db.select(_db.courses)..where(
              (Courses c) =>
                  c.profileId.equals(profileId.value) &
                  c.id.equals(resourceId.value) &
                  c.deletedAtUtc.isNull(),
            ))
            .getSingleOrNull();
    return row == null ? null : LearningMapper.resourceFromRow(row);
  }

  @override
  Future<List<LearningItem>> itemsOf(
    ProfileId profileId,
    LearningResourceId resourceId,
  ) async {
    final List<LearningItemRow> rows =
        await (_db.select(_db.learningItems)
              ..where(
                (LearningItems i) =>
                    i.profileId.equals(profileId.value) &
                    i.courseId.equals(resourceId.value),
              )
              ..orderBy(<OrderClauseGenerator<LearningItems>>[
                (LearningItems i) => OrderingTerm.asc(i.rank),
                (LearningItems i) => OrderingTerm.asc(i.id),
              ]))
            .get();
    return rows.map(LearningMapper.itemFromRow).toList(growable: false);
  }

  @override
  Future<List<StudySession>> currentSessionsOf(
    ProfileId profileId,
    LearningResourceId resourceId,
  ) async {
    final List<StudySessionRow> rows =
        await (_db.select(_db.studySessions)
              ..where(
                (StudySessions s) =>
                    s.profileId.equals(profileId.value) &
                    s.courseId.equals(resourceId.value) &
                    s.isCurrent.equals(true),
              )
              ..orderBy(<OrderClauseGenerator<StudySessions>>[
                (StudySessions s) => OrderingTerm.desc(s.startedAtUtc),
                (StudySessions s) => OrderingTerm.desc(s.id),
              ]))
            .get();
    return rows.map(LearningMapper.sessionFromRow).toList(growable: false);
  }

  @override
  Future<List<StudySessionEvent>> sessionEvents(
    ProfileId profileId,
    String logicalId,
  ) async {
    final List<StudySessionEventRow> rows =
        await (_db.select(_db.studySessionEvents)
              ..where(
                (StudySessionEvents e) =>
                    e.profileId.equals(profileId.value) &
                    e.logicalId.equals(logicalId),
              )
              ..orderBy(<OrderClauseGenerator<StudySessionEvents>>[
                (StudySessionEvents e) => OrderingTerm.asc(e.occurredAtUtc),
                (StudySessionEvents e) => OrderingTerm.asc(e.id),
              ]))
            .get();
    return rows.map(LearningMapper.eventFromRow).toList(growable: false);
  }

  @override
  Future<LearningProgress> progressOf(
    ProfileId profileId,
    LearningResourceId resourceId,
  ) async {
    final LearningResource? resource = await findResource(
      profileId,
      resourceId,
    );
    if (resource == null) {
      return LearningProgress.notStarted;
    }
    final List<LearningItem> items = await itemsOf(profileId, resourceId);
    return LearningPolicies.deriveProgress(
      items,
      mode: resource.progressMode,
      manualPermille: resource.manualProgressPermille,
    );
  }

  @override
  Future<ResumePoint> resumePoint(
    ProfileId profileId,
    LearningResourceId resourceId,
  ) async {
    final List<LearningItem> items = await itemsOf(profileId, resourceId);
    // The most recent current study session that named an item marks where the
    // user last worked (R-LEARN-003). Read-only: nothing is mutated.
    final List<StudySessionRow> recent =
        await (_db.select(_db.studySessions)
              ..where(
                (StudySessions s) =>
                    s.profileId.equals(profileId.value) &
                    s.courseId.equals(resourceId.value) &
                    s.isCurrent.equals(true) &
                    s.itemId.isNotNull(),
              )
              ..orderBy(<OrderClauseGenerator<StudySessions>>[
                (StudySessions s) => OrderingTerm.desc(s.startedAtUtc),
                (StudySessions s) => OrderingTerm.desc(s.id),
              ])
              ..limit(1))
            .get();
    final String? lastStudiedItemId = recent.isEmpty
        ? null
        : recent.single.itemId;
    return LearningPolicies.resolveResume(
      items,
      lastStudiedItemId: lastStudiedItemId,
    );
  }

  @override
  Future<StudyRecommendation?> activeStudyRecommendation(
    ProfileId profileId, {
    LifeAreaId? lifeAreaId,
  }) async {
    // Build an ordered, deduplicated candidate list: the most recently studied
    // resources first (R-LEARN-003 resume point), then in-progress resources by
    // recency. Everything here is read-only — Today never mutates a resource.
    final List<_ResumeCandidate> studied = await _recentlyStudiedResources(
      profileId,
      lifeAreaId: lifeAreaId,
    );
    final List<String> inProgress = await _inProgressResourceIds(
      profileId,
      lifeAreaId: lifeAreaId,
    );

    final Set<String> seen = <String>{};
    final List<_ResumeCandidate> ordered = <_ResumeCandidate>[];
    for (final _ResumeCandidate candidate in studied) {
      if (seen.add(candidate.resourceId)) {
        ordered.add(candidate);
      }
    }
    for (final String id in inProgress) {
      if (seen.add(id)) {
        ordered.add(_ResumeCandidate(resourceId: id, studied: false));
      }
    }

    for (final _ResumeCandidate candidate in ordered) {
      final LearningResource? resource = await findResource(
        profileId,
        LearningResourceId(candidate.resourceId),
      );
      if (resource == null) {
        continue;
      }
      final ResumePoint resume = await resumePoint(profileId, resource.id);
      if (resume.itemId == null) {
        continue; // fully complete / nothing to resume
      }
      final List<LearningItem> items = await itemsOf(profileId, resource.id);
      String? resumeItemTitle;
      for (final LearningItem item in items) {
        if (item.id == resume.itemId) {
          resumeItemTitle = item.title;
          break;
        }
      }
      return StudyRecommendation(
        resourceId: resource.id.value,
        resourceTitle: resource.title,
        resumeItemId: resume.itemId,
        resumeItemTitle: resumeItemTitle,
        reason: candidate.studied ? resume.reason : 'in_progress',
      );
    }
    return null;
  }

  /// The resources with a current study session, most recently studied first.
  Future<List<_ResumeCandidate>> _recentlyStudiedResources(
    ProfileId profileId, {
    LifeAreaId? lifeAreaId,
  }) async {
    final StringBuffer sql = StringBuffer(
      'SELECT s.course_id AS course_id FROM study_sessions s '
      'JOIN courses c ON c.profile_id = s.profile_id AND c.id = s.course_id '
      'WHERE s.profile_id = ? AND s.is_current = 1 '
      'AND c.deleted_at_utc IS NULL',
    );
    final List<Variable<Object>> vars = <Variable<Object>>[
      Variable<String>(profileId.value),
    ];
    if (lifeAreaId != null) {
      sql.write(' AND c.life_area_id = ?');
      vars.add(Variable<String>(lifeAreaId.value));
    }
    sql.write(' ORDER BY s.started_at_utc DESC, s.id DESC');
    final List<QueryRow> rows = await _db
        .customSelect(sql.toString(), variables: vars)
        .get();
    return rows
        .map(
          (QueryRow r) => _ResumeCandidate(
            resourceId: r.data['course_id'] as String,
            studied: true,
          ),
        )
        .toList(growable: false);
  }

  /// The active / on-hold resources ordered by most recent update. Completed,
  /// archived, and soft-deleted resources are excluded.
  Future<List<String>> _inProgressResourceIds(
    ProfileId profileId, {
    LifeAreaId? lifeAreaId,
  }) async {
    final StringBuffer sql = StringBuffer(
      'SELECT c.id AS id FROM courses c '
      'WHERE c.profile_id = ? AND c.deleted_at_utc IS NULL '
      'AND c.status IN (?, ?)',
    );
    final List<Variable<Object>> vars = <Variable<Object>>[
      Variable<String>(profileId.value),
      Variable<String>(LearningResourceStatus.active.wire),
      Variable<String>(LearningResourceStatus.onHold.wire),
    ];
    if (lifeAreaId != null) {
      sql.write(' AND c.life_area_id = ?');
      vars.add(Variable<String>(lifeAreaId.value));
    }
    sql.write(' ORDER BY c.updated_at_utc DESC, c.id DESC');
    final List<QueryRow> rows = await _db
        .customSelect(sql.toString(), variables: vars)
        .get();
    return rows
        .map((QueryRow r) => r.data['id'] as String)
        .toList(growable: false);
  }

  @override
  Future<LearningStatistics> statistics(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
    LearningResourceId? resourceId,
  }) async {
    final List<TimeSpan> intervals = await studyIntervals(
      profileId,
      rangeStartUtc: rangeStartUtc,
      rangeEndUtc: rangeEndUtc,
      lifeAreaId: lifeAreaId,
      resourceId: resourceId,
    );
    // Spans are microsecond windows; union then convert to whole seconds
    // (R-LEARN-005, R-FOCUS-005).
    final int studied =
        LearningPolicies.unionDuration(intervals) ~/
        StudySession.microsPerSecond;
    final int completed = await _completedItemCount(
      profileId,
      rangeStartUtc: rangeStartUtc,
      rangeEndUtc: rangeEndUtc,
      lifeAreaId: lifeAreaId,
      resourceId: resourceId,
    );
    return LearningStatistics(
      rangeStartUtc: rangeStartUtc,
      rangeEndUtc: rangeEndUtc,
      studiedDurationSec: studied,
      completedItems: completed,
      sessionCount: intervals.length,
      lifeAreaId: lifeAreaId?.value,
      resourceId: resourceId?.value,
    );
  }

  @override
  Future<List<TimeSpan>> studyIntervals(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
    LearningResourceId? resourceId,
  }) async {
    // Current sessions whose `[started_at_utc, ended_at_utc)` microsecond window
    // overlaps the requested range.
    final StringBuffer sql = StringBuffer(
      'SELECT s.started_at_utc AS start_at, s.ended_at_utc AS end_at '
      'FROM study_sessions s '
      'JOIN courses c ON c.profile_id = s.profile_id AND c.id = s.course_id '
      'WHERE s.profile_id = ? AND s.is_current = 1 '
      'AND s.started_at_utc < ? '
      'AND s.ended_at_utc > ?',
    );
    final List<Variable<Object>> vars = <Variable<Object>>[
      Variable<String>(profileId.value),
      Variable<int>(rangeEndUtc),
      Variable<int>(rangeStartUtc),
    ];
    if (lifeAreaId != null) {
      sql.write(' AND c.life_area_id = ?');
      vars.add(Variable<String>(lifeAreaId.value));
    }
    if (resourceId != null) {
      sql.write(' AND s.course_id = ?');
      vars.add(Variable<String>(resourceId.value));
    }
    final List<QueryRow> rows = await _db
        .customSelect(sql.toString(), variables: vars)
        .get();
    return rows
        .map((QueryRow r) {
          final int start = r.data['start_at'] as int;
          final int end = r.data['end_at'] as int;
          // Clip to the requested range so the union covers only in-range time.
          final int clippedStart = start < rangeStartUtc
              ? rangeStartUtc
              : start;
          final int clippedEnd = end > rangeEndUtc ? rangeEndUtc : end;
          return TimeSpan(startUtc: clippedStart, endUtc: clippedEnd);
        })
        .toList(growable: false);
  }

  Future<int> _completedItemCount(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
    LearningResourceId? resourceId,
  }) async {
    final StringBuffer sql = StringBuffer(
      'SELECT COUNT(*) AS n FROM learning_items i '
      'JOIN courses c ON c.profile_id = i.profile_id AND c.id = i.course_id '
      'WHERE i.profile_id = ? '
      'AND i.completed_at_utc IS NOT NULL '
      'AND i.completed_at_utc >= ? AND i.completed_at_utc < ? '
      // Eligible leaves only (sections never count) (R-LEARN-004).
      "AND i.item_type <> 'section'",
    );
    final List<Variable<Object>> vars = <Variable<Object>>[
      Variable<String>(profileId.value),
      Variable<int>(rangeStartUtc),
      Variable<int>(rangeEndUtc),
    ];
    if (lifeAreaId != null) {
      sql.write(' AND c.life_area_id = ?');
      vars.add(Variable<String>(lifeAreaId.value));
    }
    if (resourceId != null) {
      sql.write(' AND i.course_id = ?');
      vars.add(Variable<String>(resourceId.value));
    }
    final List<QueryRow> rows = await _db
        .customSelect(sql.toString(), variables: vars)
        .get();
    return rows.single.data['n'] as int;
  }
}

/// An ordered resume candidate resource id plus whether it came from study
/// history (so the recommendation reason is `last_studied`/`first_incomplete`)
/// or the in-progress fallback (`in_progress`).
final class _ResumeCandidate {
  const _ResumeCandidate({required this.resourceId, required this.studied});

  final String resourceId;
  final bool studied;
}
