import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/home/application/home_layout_store.dart';
import 'package:forge/features/home/domain/home_layout.dart';

/// Durable [HomeLayoutStore] backed by the profile-owned `settings` table
/// (R-HOME-002, R-GEN-001).
///
/// The preference is a single area-free setting row keyed by
/// [_settingKey]. It is not sync-eligible domain data, so it is written with a
/// plain idempotent upsert rather than through the command bus; the active
/// local generation remains the source of truth and the value is fully
/// reconstructible on startup (R-HOME-005).
final class SettingsHomeLayoutStore implements HomeLayoutStore {
  SettingsHomeLayoutStore(this._db, this._clock);

  final ForgeSchemaDatabase _db;
  final Clock _clock;

  static const String _settingKey = 'home.layout.v1';
  static const int _schemaVersion = 1;

  @override
  Future<HomeLayout> load(ProfileId profileId) async {
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
      return HomeLayout.defaultLayout;
    }
    return HomeLayoutCodec.decode(rows.single.data['value'] as String?);
  }

  @override
  Future<void> save(ProfileId profileId, HomeLayout layout) async {
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
        HomeLayoutCodec.encode(layout),
        now,
      ],
    );
  }
}
