import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/areas/application/life_area_query_service.dart';

/// Drift-backed [LifeAreaQueryService] over the `life_areas` table (R-GEN-002).
///
/// Reads run against the active local generation, so results are available
/// offline (R-GEN-001). Areas are returned ordered by their lexical rank with
/// the id as a deterministic tie-breaker.
final class LifeAreaReadRepository implements LifeAreaQueryService {
  LifeAreaReadRepository(this._db);

  final ForgeSchemaDatabase _db;

  @override
  Future<List<LifeAreaSummary>> list(
    ProfileId profileId, {
    bool includeArchived = true,
  }) async {
    final String archivedClause = includeArchived
        ? ''
        : 'AND archived_at_utc IS NULL ';
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT id, name, rank, is_default, archived_at_utc '
          'FROM life_areas WHERE profile_id = ? AND deleted_at_utc IS NULL '
          '$archivedClause'
          'ORDER BY rank ASC, id ASC',
          variables: <Variable<Object>>[Variable<String>(profileId.value)],
        )
        .get();
    return rows
        .map(
          (QueryRow r) => LifeAreaSummary(
            id: LifeAreaId(r.data['id'] as String),
            name: r.data['name'] as String,
            rank: r.data['rank'] as String,
            isDefault: (r.data['is_default'] as int) == 1,
            isArchived: r.data['archived_at_utc'] != null,
          ),
        )
        .toList(growable: false);
  }
}
