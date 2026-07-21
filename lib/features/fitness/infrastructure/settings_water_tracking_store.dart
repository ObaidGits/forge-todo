import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/fitness/application/water_tracking_settings.dart';

/// Durable [WaterTrackingSettings] backed by the profile-owned `settings` table
/// (R-FIT-003, R-GEN-001).
///
/// The preference is a single area-free setting row keyed by [_settingKey]. It
/// is a local device preference, not sync-eligible domain data, so it is
/// written with a plain idempotent upsert rather than through the command bus
/// (mirrors the Today layout and saved-filters stores). A missing row means the
/// default: disabled. The value is stored as the literal string `'1'`/`'0'` so
/// it is fully reconstructible on startup.
final class SettingsWaterTrackingStore implements WaterTrackingSettings {
  SettingsWaterTrackingStore(this._db, this._clock);

  final ForgeSchemaDatabase _db;
  final Clock _clock;

  static const String _settingKey = 'fitness.water_tracking.enabled.v1';
  static const int _schemaVersion = 1;

  @override
  Future<bool> isEnabled(ProfileId profileId) async {
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
      // Disabled by default (R-FIT-003).
      return false;
    }
    return rows.single.data['value'] == '1';
  }

  @override
  Future<void> setEnabled(ProfileId profileId, {required bool enabled}) async {
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
        enabled ? '1' : '0',
        now,
      ],
    );
  }
}
