import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/goal.dart';
import 'package:forge/features/goals/domain/goal_repository.dart';
import 'package:forge/features/goals/domain/milestone.dart';
import 'package:forge/features/goals/infrastructure/goal_mapper.dart';
import 'package:forge/features/goals/infrastructure/milestone_mapper.dart';

/// Drift-backed read model for goals and milestones (R-GOAL-002, R-GOAL-007).
///
/// Reads run against the active local generation, which is the client source of
/// truth (design.md §8). Structured filters compose with AND; free text is a
/// simple `LIKE` fallback — unified FTS text search is served by the search
/// read model (R-SEARCH-001).
final class GoalReadRepository implements GoalRepository {
  GoalReadRepository(this._db);

  final ForgeSchemaDatabase _db;

  @override
  Future<Goal?> findById(ProfileId profileId, GoalId goalId) async {
    final GoalRow? row =
        await (_db.select(_db.goals)..where(
              (Goals t) =>
                  t.profileId.equals(profileId.value) &
                  t.id.equals(goalId.value),
            ))
            .getSingleOrNull();
    return row == null ? null : GoalMapper.fromRow(row);
  }

  @override
  Future<List<Goal>> query(ProfileId profileId, GoalQuery filter) async {
    final _WhereClause where = _buildWhere(profileId, filter);
    final String order = filter.onlyDeleted
        ? 'ORDER BY deleted_at_utc DESC, id DESC'
        : (filter.archived == true
              ? 'ORDER BY archived_at_utc DESC, id DESC'
              : 'ORDER BY rank ASC, id ASC');
    final String limit = filter.limit == null ? '' : 'LIMIT ${filter.limit}';
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT * FROM goals WHERE ${where.sql} $order $limit',
          variables: where.variables,
        )
        .get();
    return rows
        .map((QueryRow r) => GoalMapper.fromRow(_db.goals.map(r.data)))
        .toList(growable: false);
  }

  @override
  Future<List<Goal>> view(
    ProfileId profileId,
    GoalViewKind kind, {
    LifeAreaId? lifeAreaId,
  }) {
    switch (kind) {
      case GoalViewKind.active:
        return query(
          profileId,
          GoalQuery(lifeAreaId: lifeAreaId, archived: false),
        );
      case GoalViewKind.archived:
        return query(
          profileId,
          GoalQuery(lifeAreaId: lifeAreaId, archived: true),
        );
      case GoalViewKind.trash:
        return query(
          profileId,
          GoalQuery(lifeAreaId: lifeAreaId, onlyDeleted: true),
        );
    }
  }

  @override
  Future<List<String>> tagIdsFor(ProfileId profileId, GoalId goalId) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT tag_id FROM entity_tags '
          "WHERE profile_id = ? AND entity_type = 'goal' AND entity_id = ? "
          'ORDER BY tag_id ASC',
          variables: <Variable<Object>>[
            Variable<String>(profileId.value),
            Variable<String>(goalId.value),
          ],
        )
        .get();
    return rows
        .map((QueryRow r) => r.data['tag_id'] as String)
        .toList(growable: false);
  }

  @override
  Future<List<Milestone>> milestonesOf(
    ProfileId profileId,
    GoalId goalId,
  ) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT * FROM milestones WHERE profile_id = ? AND goal_id = ? '
          'AND deleted_at_utc IS NULL ORDER BY rank ASC, id ASC',
          variables: <Variable<Object>>[
            Variable<String>(profileId.value),
            Variable<String>(goalId.value),
          ],
        )
        .get();
    return rows
        .map(
          (QueryRow r) => MilestoneMapper.fromRow(_db.milestones.map(r.data)),
        )
        .toList(growable: false);
  }

  @override
  Future<Milestone?> findMilestone(
    ProfileId profileId,
    MilestoneId milestoneId,
  ) async {
    final MilestoneRow? row =
        await (_db.select(_db.milestones)..where(
              (Milestones t) =>
                  t.profileId.equals(profileId.value) &
                  t.id.equals(milestoneId.value),
            ))
            .getSingleOrNull();
    return row == null ? null : MilestoneMapper.fromRow(row);
  }

  _WhereClause _buildWhere(ProfileId profileId, GoalQuery f) {
    final List<String> clauses = <String>['profile_id = ?'];
    final List<Variable<Object>> vars = <Variable<Object>>[
      Variable<String>(profileId.value),
    ];

    if (f.onlyDeleted) {
      clauses.add('deleted_at_utc IS NOT NULL');
    } else if (!f.includeDeleted) {
      clauses.add('deleted_at_utc IS NULL');
    }

    if (f.lifeAreaId != null) {
      clauses.add('life_area_id = ?');
      vars.add(Variable<String>(f.lifeAreaId!.value));
    }
    if (f.archived != null) {
      clauses.add(
        f.archived! ? 'archived_at_utc IS NOT NULL' : 'archived_at_utc IS NULL',
      );
    }
    if (f.statuses != null && f.statuses!.isNotEmpty) {
      final List<String> placeholders = <String>[];
      for (final status in f.statuses!) {
        placeholders.add('?');
        vars.add(Variable<String>(status.wire));
      }
      clauses.add('status IN (${placeholders.join(', ')})');
    }
    if (f.targetFromDate != null) {
      clauses.add('target_date >= ?');
      vars.add(Variable<String>(f.targetFromDate!));
    }
    if (f.targetToDate != null) {
      clauses.add('target_date <= ?');
      vars.add(Variable<String>(f.targetToDate!));
    }
    if (f.tagId != null) {
      clauses.add(
        'id IN (SELECT entity_id FROM entity_tags '
        "WHERE profile_id = ? AND entity_type = 'goal' AND tag_id = ?)",
      );
      vars
        ..add(Variable<String>(profileId.value))
        ..add(Variable<String>(f.tagId!));
    }
    if (f.titleContains != null && f.titleContains!.isNotEmpty) {
      clauses.add("title LIKE ? ESCAPE '\\'");
      vars.add(Variable<String>('%${_escapeLike(f.titleContains!)}%'));
    }

    return _WhereClause(clauses.join(' AND '), vars);
  }

  static String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');
}

final class _WhereClause {
  const _WhereClause(this.sql, this.variables);

  final String sql;
  final List<Variable<Object>> variables;
}
