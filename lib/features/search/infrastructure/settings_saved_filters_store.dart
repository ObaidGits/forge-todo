import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/search/application/saved_filters_store.dart';
import 'package:forge/features/search/domain/saved_search_filter.dart';

/// Durable [SavedFiltersStore] backed by the profile-owned `settings` table
/// (R-SEARCH-002, R-GEN-001).
///
/// Saved filters are a single area-free setting row keyed by [_settingKey],
/// serialized as a JSON array. They are local, non-sync preference data, so
/// they are written with a plain idempotent upsert in one transactional
/// statement rather than through the sync-eligible command bus; the active
/// local generation stays the source of truth and the value is fully
/// reconstructible on startup (mirrors the Today layout store).
final class SettingsSavedFiltersStore implements SavedFiltersStore {
  SettingsSavedFiltersStore(this._db, this._clock);

  final ForgeSchemaDatabase _db;
  final Clock _clock;

  static const String _settingKey = 'search.saved_filters.v1';
  static const int _schemaVersion = 1;

  @override
  Future<List<SavedSearchFilter>> load(ProfileId profileId) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT value FROM settings WHERE profile_id = ? AND setting_key = ?',
          variables: <Variable<Object>>[
            Variable<String>(profileId.value),
            const Variable<String>(_settingKey),
          ],
        )
        .get();
    if (rows.isEmpty) {
      return const <SavedSearchFilter>[];
    }
    return _decode(rows.single.data['value'] as String?);
  }

  @override
  Future<void> save(
    ProfileId profileId,
    List<SavedSearchFilter> filters,
  ) async {
    final int now = _clock.utcNow().microsecondsSinceEpoch;
    await _db.customStatement(
      'INSERT INTO settings '
      '(profile_id, setting_key, schema_version, is_encrypted, value, '
      'updated_at_utc) VALUES (?, ?, ?, 0, ?, ?) '
      'ON CONFLICT(profile_id, setting_key) DO UPDATE SET '
      'value = excluded.value, schema_version = excluded.schema_version, '
      'updated_at_utc = excluded.updated_at_utc',
      <Object?>[
        profileId.value,
        _settingKey,
        _schemaVersion,
        _encode(filters),
        now,
      ],
    );
  }

  static String _encode(List<SavedSearchFilter> filters) => jsonEncode(
    filters
        .map(
          (SavedSearchFilter f) => <String, Object?>{
            'id': f.id,
            'name': f.name,
            'query': f.query,
            'types': f.types.toList(growable: false),
          },
        )
        .toList(growable: false),
  );

  static List<SavedSearchFilter> _decode(String? value) {
    if (value == null || value.isEmpty) {
      return const <SavedSearchFilter>[];
    }
    final Object? decoded = jsonDecode(value);
    if (decoded is! List) {
      return const <SavedSearchFilter>[];
    }
    final List<SavedSearchFilter> filters = <SavedSearchFilter>[];
    for (final Object? entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      final Object? id = entry['id'];
      final Object? name = entry['name'];
      final Object? query = entry['query'];
      if (id is! String || name is! String || query is! String) {
        continue;
      }
      final Object? rawTypes = entry['types'];
      final Set<String> types = rawTypes is List
          ? rawTypes.whereType<String>().toSet()
          : <String>{};
      filters.add(
        SavedSearchFilter(id: id, name: name, query: query, types: types),
      );
    }
    return filters;
  }
}
