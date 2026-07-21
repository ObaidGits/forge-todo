import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// Reminders schema (data-model §3 "Tasks and reminders"; R-NOTIFY-001..006,
// R-GEN-004, R-GEN-005).
// ---------------------------------------------------------------------------
//
// `reminders` is an inherited-through-strict-owner table with a *polymorphic*
// owner (`owner_type`, `owner_id`) validated by the centralized owner registry
// in the writing transaction, because SQLite cannot FK across entity types
// (data-model §1/§3). It carries `profile_id` and rejects cross-profile rows
// through the profile foreign key.
//
// A reminder fires at EITHER a fixed wall-clock local time (`absolute_local` in
// the preserved `timezone_id`) OR a signed minute offset relative to its
// owner's due instant, never both. `next_fire_at_utc`, `token`,
// `snoozed_until_utc`, `delivery_status`, and `last_diagnostic_code` are the
// local-only reconciliation projection (never replicated) and are recomputed
// on every rolling-horizon pass (R-NOTIFY-004).

/// Unified reminder model rows for every MVP aggregate type.
@DataClassName('ReminderRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_reminders_profile_id ON reminders (profile_id, id)',
)
@TableIndex.sql(
  'CREATE INDEX ix_reminders_due '
  'ON reminders (profile_id, enabled, next_fire_at_utc) '
  'WHERE deleted_at_utc IS NULL',
)
@TableIndex(
  name: 'ix_reminders_owner',
  columns: {#profileId, #ownerType, #ownerId},
)
class Reminders extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get ownerType => text()();
  TextColumn get ownerId => text()();
  TextColumn get category => text()();
  TextColumn get triggerKind => text()();
  TextColumn get absoluteLocal => text().nullable()();
  IntColumn get offsetMinutes => integer().nullable()();
  TextColumn get timezoneId => text()();
  TextColumn get dstPolicy => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant<bool>(true))();
  IntColumn get nextFireAtUtc => integer().nullable()();
  IntColumn get snoozedUntilUtc => integer().nullable()();
  TextColumn get token => text().nullable()();
  TextColumn get deliveryStatus => text()();
  TextColumn get lastDiagnosticCode => text().nullable()();
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
    "CHECK (owner_type IN ('task', 'habit', 'study', 'deadline', 'workout'))",
    "CHECK (category IN ('task', 'habit', 'study', 'deadline', 'workout'))",
    "CHECK (trigger_kind IN ('absolute', 'offset'))",
    // absolute XOR offset: exactly one trigger form is populated.
    ("CHECK ((trigger_kind = 'absolute' AND absolute_local IS NOT NULL "
        'AND offset_minutes IS NULL) OR '
        "(trigger_kind = 'offset' AND offset_minutes IS NOT NULL "
        'AND absolute_local IS NULL))'),
    ("CHECK (dst_policy IN "
        "('forward_gap_earlier_overlap', 'backward_gap_later_overlap'))"),
    ("CHECK (delivery_status IN "
        "('pending', 'scheduled', 'skipped', 'failed'))"),
    'CHECK (revision >= 1)',
  ];
}
