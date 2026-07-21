import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/areas/domain/life_area.dart';
import 'package:forge/features/areas/domain/life_area_rank.dart';

/// Transaction-scoped write access to the `life_areas` table (R-GEN-002).
///
/// Created per transaction by the unit of work and resolved from the session
/// repository set inside a command body (design.md §5). The shared [scope]
/// rejects any use after the owning transaction completes.
final class LifeAreaWriteRepository {
  LifeAreaWriteRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;

  /// Loads a non-deleted area by id for [profileId], or null when absent.
  Future<LifeArea?> find(String profileId, String areaId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT id, profile_id, name, rank, is_default, archived_at_utc, '
          'created_at_utc, updated_at_utc FROM life_areas '
          'WHERE profile_id = ? AND id = ? AND deleted_at_utc IS NULL',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(areaId),
          ],
        )
        .get();
    if (rows.isEmpty) {
      return null;
    }
    return _fromRow(rows.single.data);
  }

  /// The id of a non-deleted area whose normalized name equals [normalizedName]
  /// for [profileId], or null when the name is free. Used to enforce
  /// case-insensitive uniqueness (R-GEN-002).
  Future<String?> findIdByNormalizedName(
    String profileId,
    String normalizedName,
  ) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT id FROM life_areas WHERE profile_id = ? '
          'AND normalized_name = ? AND deleted_at_utc IS NULL LIMIT 1',
          variables: <Variable<Object>>[
            Variable<String>(profileId),
            Variable<String>(normalizedName),
          ],
        )
        .get();
    return rows.isEmpty ? null : rows.single.data['id'] as String;
  }

  /// The highest existing rank among non-deleted areas, used to append.
  Future<LifeAreaRank?> lastRank(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT rank FROM life_areas WHERE profile_id = ? '
          'AND deleted_at_utc IS NULL ORDER BY rank DESC, id DESC LIMIT 1',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return rows.isEmpty
        ? null
        : LifeAreaRank(rows.single.data['rank'] as String);
  }

  Future<void> insert(LifeArea area) async {
    scope.ensureActive();
    await db.customStatement(
      'INSERT INTO life_areas '
      '(id, profile_id, name, normalized_name, rank, is_default, '
      'archived_at_utc, created_at_utc, updated_at_utc) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        area.id.value,
        area.profileId.value,
        area.name,
        area.normalizedName,
        area.rank.value,
        area.isDefault ? 1 : 0,
        area.archivedAtUtc,
        area.createdAtUtc,
        area.updatedAtUtc,
      ],
    );
  }

  /// Writes every mutable column of [area] for its `(profile_id, id)`.
  Future<void> update(LifeArea area) async {
    scope.ensureActive();
    await db.customStatement(
      'UPDATE life_areas SET name = ?, normalized_name = ?, rank = ?, '
      'is_default = ?, archived_at_utc = ?, updated_at_utc = ? '
      'WHERE profile_id = ? AND id = ?',
      <Object?>[
        area.name,
        area.normalizedName,
        area.rank.value,
        area.isDefault ? 1 : 0,
        area.archivedAtUtc,
        area.updatedAtUtc,
        area.profileId.value,
        area.id.value,
      ],
    );
  }

  /// Clears the default flag from every area of [profileId] except [keepId].
  /// Used so at most one default area exists after a `makeDefault` (R-GEN-002).
  Future<void> clearDefaultExcept({
    required String profileId,
    required String keepId,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    await db.customStatement(
      'UPDATE life_areas SET is_default = 0, updated_at_utc = ? '
      'WHERE profile_id = ? AND id <> ? AND is_default = 1 '
      'AND deleted_at_utc IS NULL',
      <Object?>[nowUtc, profileId, keepId],
    );
  }

  /// The current epoch stamped on outbox operations. Falls back to `0` before a
  /// sync profile link exists.
  Future<int> currentEpoch(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT COALESCE(MAX(epoch), 0) AS e FROM sync_cursors '
          'WHERE profile_id = ?',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return rows.single.data['e'] as int;
  }

  LifeArea _fromRow(Map<String, Object?> data) => LifeArea(
    id: LifeAreaId(data['id'] as String),
    profileId: ProfileId(data['profile_id'] as String),
    name: data['name'] as String,
    rank: LifeAreaRank(data['rank'] as String),
    isDefault: (data['is_default'] as int) == 1,
    archivedAtUtc: data['archived_at_utc'] as int?,
    createdAtUtc: data['created_at_utc'] as int,
    updatedAtUtc: data['updated_at_utc'] as int,
  );
}
