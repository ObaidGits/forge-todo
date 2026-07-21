import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// Conventions (data-model.md §1)
// ---------------------------------------------------------------------------
// * Local primary keys are UUIDv7 text generated before persistence.
// * Instants are integer UTC microseconds; date-only fields are ISO strings.
// * Booleans use drift's checked-integer columns (CHECK col IN (0,1)).
// * Enums use stable lowercase strings validated by CHECK constraints.
// * Every table stores `profile_id` (except database-global operational
//   singletons) and rejects cross-profile references through composite FKs or
//   the centralized owner registry.
// * Foreign keys are enabled at open time; parent-owned children cascade only
//   during approved hard purge (not modelled here — ordinary delete tombstones).
//
// Composite foreign keys and CHECK constraints are declared through
// [customConstraints] so the exact release DDL is auditable in one place.

/// Installation root. V1 permits exactly one active `profiles` row per
/// installation; the partial unique index enforces it.
@DataClassName('ProfileRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_profiles_active '
  'ON profiles (is_active) WHERE is_active = 1',
)
class Profiles extends Table {
  TextColumn get id => text()();
  TextColumn get displayName => text()();
  TextColumn get locale => text()();
  TextColumn get timezoneId => text()();
  IntColumn get weekStart => integer()();
  TextColumn get hourFormat => text()();
  IntColumn get planningDayBoundaryMinutes =>
      integer().withDefault(const Constant<int>(0))();
  BoolColumn get isActive => boolean()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();
  IntColumn get deletedAtUtc => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'CHECK (week_start BETWEEN 0 AND 6)',
    "CHECK (hour_format IN ('h12', 'h24'))",
  ];
}

/// Registered devices for a profile.
@DataClassName('DeviceRow')
@TableIndex(
  name: 'ix_devices_profile_revoked',
  columns: {#profileId, #revokedAtUtc},
)
class Devices extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get name => text()();
  TextColumn get platform => text()();
  TextColumn get publicKey => text().nullable()();
  IntColumn get lastSeenAtUtc => integer().nullable()();
  IntColumn get revokedAtUtc => integer().nullable()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
  ];
}

/// Life Area taxonomy. `UNIQUE(profile_id, id)` makes the composite parent key
/// referenceable by every direct-area owner in later waves.
@DataClassName('LifeAreaRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_life_areas_name '
  'ON life_areas (profile_id, normalized_name) WHERE deleted_at_utc IS NULL',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_life_areas_default '
  'ON life_areas (profile_id) WHERE is_default = 1 AND deleted_at_utc IS NULL',
)
@TableIndex(name: 'ix_life_areas_rank', columns: {#profileId, #rank})
class LifeAreas extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get name => text()();
  TextColumn get normalizedName => text()();
  TextColumn get icon => text().nullable()();
  TextColumn get color => text().nullable()();
  TextColumn get rank => text()();
  BoolColumn get isDefault =>
      boolean().withDefault(const Constant<bool>(false))();
  IntColumn get archivedAtUtc => integer().nullable()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();
  IntColumn get deletedAtUtc => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
  ];
}

/// Tags. `UNIQUE(profile_id, id)` lets `entity_tags` reject cross-profile tags
/// through a composite foreign key.
@DataClassName('TagRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_tags_name '
  'ON tags (profile_id, normalized_name) WHERE deleted_at_utc IS NULL',
)
class Tags extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get normalizedName => text()();
  TextColumn get displayName => text()();
  TextColumn get color => text().nullable()();
  IntColumn get archivedAtUtc => integer().nullable()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();
  IntColumn get deletedAtUtc => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'UNIQUE (profile_id, id)',
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
  ];
}

/// Polymorphic tag attachments. Ownership is validated by the centralized owner
/// registry in the writing transaction; the composite tag FK rejects
/// cross-profile tags at the database boundary.
@DataClassName('EntityTagRow')
@TableIndex(
  name: 'ix_entity_tags_reverse',
  columns: {#profileId, #tagId, #entityType, #entityId},
)
class EntityTags extends Table {
  TextColumn get profileId => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get tagId => text()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{
    profileId,
    entityType,
    entityId,
    tagId,
  };

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    'FOREIGN KEY (profile_id, tag_id) REFERENCES tags (profile_id, id)',
  ];
}

/// Polymorphic typed links between entities. Application-validated and
/// integrity-scanned because SQLite cannot FK across entity types.
@DataClassName('EntityLinkRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_entity_links_tuple '
  'ON entity_links '
  '(profile_id, from_type, from_id, relation, to_type, to_id)',
)
@TableIndex(
  name: 'ix_entity_links_reverse',
  columns: {#profileId, #toType, #toId, #relation},
)
class EntityLinks extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get fromType => text()();
  TextColumn get fromId => text()();
  TextColumn get relation => text()();
  TextColumn get toType => text()();
  TextColumn get toId => text()();
  TextColumn get rank => text()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
  ];
}

/// Typed user/device settings. `is_encrypted` marks values wrapped outside
/// SQLite; encrypted values are stored as opaque blobs.
@DataClassName('SettingRow')
class Settings extends Table {
  TextColumn get profileId => text()();
  TextColumn get settingKey => text()();
  IntColumn get schemaVersion => integer()();
  BoolColumn get isEncrypted =>
      boolean().withDefault(const Constant<bool>(false))();
  TextColumn get value => text().nullable()();
  BlobColumn get encryptedValue => blob().nullable()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{profileId, settingKey};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
  ];
}

// ---------------------------------------------------------------------------
// Commit sequence, receipts, journal, activity, dirty projections
// ---------------------------------------------------------------------------

/// Monotonic local commit sequence per profile.
@DataClassName('CommitLogRow')
@TableIndex(name: 'ix_commit_log_command', columns: {#profileId, #commandId})
class CommitLog extends Table {
  TextColumn get profileId => text()();
  IntColumn get commitSeq => integer()();
  TextColumn get commandId => text()();
  TextColumn get writeOrigin => text()();
  IntColumn get committedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{profileId, commitSeq};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    ("CHECK (write_origin IN "
        "('local_command','remote_apply','bootstrap_rebase',"
        "'restore','migration'))"),
  ];
}

/// Durable command receipts keyed by `(profile_id, command_id)` (R-GEN-005).
/// Same command ID with a different request hash is rejected by the command
/// bus; the stored result code/payload version is replay-stable.
@DataClassName('CommandReceiptRow')
class CommandReceipts extends Table {
  TextColumn get profileId => text()();
  TextColumn get commandId => text()();
  TextColumn get requestHash => text()();
  TextColumn get resultCode => text()();
  TextColumn get resultPayload => text().nullable()();
  IntColumn get payloadVersion => integer()();
  IntColumn get commitSeq => integer()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{profileId, commandId};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
  ];
}

/// Immutable canonical intent for each durable command awaiting sync.
@DataClassName('PendingCommandRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_pending_command_group '
  'ON pending_command_journal (profile_id, sync_group_id) '
  'WHERE sync_group_id IS NOT NULL',
)
@TableIndex(
  name: 'ix_pending_command_state',
  columns: {#profileId, #state, #commitSeq},
)
@TableIndex(
  name: 'ix_pending_command_retention',
  columns: {#profileId, #retainedUntilUtc},
)
class PendingCommandJournal extends Table {
  TextColumn get profileId => text()();
  TextColumn get commandId => text()();
  TextColumn get commandType => text()();
  IntColumn get schemaVersion => integer()();
  TextColumn get canonicalPayload => text()();
  TextColumn get originalResultCode => text()();
  IntColumn get originalPayloadVersion => integer()();
  TextColumn get baseVersions => text().nullable()();
  IntColumn get commitSeq => integer()();
  TextColumn get syncGroupId => text().nullable()();
  TextColumn get state => text()();
  IntColumn get acknowledgedAtUtc => integer().nullable()();
  IntColumn get retainedUntilUtc => integer().nullable()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{profileId, commandId};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    ("CHECK (state IN "
        "('pending','in_flight','acknowledged','terminal_conflict'))"),
  ];
}

/// Append-only activity feed.
@DataClassName('ActivityEventRow')
@TableIndex(
  name: 'ix_activity_profile_time',
  columns: {#profileId, #occurredAtUtc},
)
@TableIndex(
  name: 'ix_activity_entity_time',
  columns: {#profileId, #entityType, #entityId, #occurredAtUtc},
)
class ActivityEvents extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get eventType => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  IntColumn get occurredAtUtc => integer()();
  IntColumn get payloadVersion => integer()();
  TextColumn get commandId => text().nullable()();
  IntColumn get commitSeq => integer()();
  TextColumn get payload => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
  ];
}

/// Durable projection dirty markers reconciled until their watermark reaches
/// the source commit sequence.
@DataClassName('ProjectionDirtyRow')
@TableIndex(
  name: 'ix_projection_dirty_seq',
  columns: {#profileId, #sourceCommitSeq},
)
class ProjectionDirty extends Table {
  TextColumn get profileId => text()();
  TextColumn get projection => text()();
  TextColumn get projectionKey => text()();
  IntColumn get sourceCommitSeq => integer()();
  IntColumn get attempts => integer().withDefault(const Constant<int>(0))();
  TextColumn get lastError => text().nullable()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{
    profileId,
    projection,
    projectionKey,
  };

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
  ];
}

// ---------------------------------------------------------------------------
// Sync and replication
// ---------------------------------------------------------------------------

/// Transactional outbox of committed, sync-eligible mutations.
@DataClassName('OutboxMutationRow')
@TableIndex(
  name: 'idx_outbox_ready',
  columns: {#profileId, #state, #nextAttemptUtc, #operationId},
)
@TableIndex(
  name: 'ix_outbox_group',
  columns: {#profileId, #groupId, #groupIndex},
)
@TableIndex(
  name: 'ix_outbox_entity',
  columns: {#profileId, #entityType, #entityId},
)
class OutboxMutations extends Table {
  TextColumn get operationId => text()();
  TextColumn get profileId => text()();
  TextColumn get groupId => text()();
  IntColumn get groupIndex => integer()();
  IntColumn get groupCount => integer()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get opKind => text()();
  TextColumn get changedFields => text().nullable()();
  IntColumn get baseRowVersion => integer().nullable()();
  TextColumn get baseFieldVersions => text().nullable()();
  IntColumn get snapshotEpoch => integer()();
  TextColumn get payload => text()();
  IntColumn get retryCount => integer().withDefault(const Constant<int>(0))();
  IntColumn get nextAttemptUtc => integer()();
  TextColumn get state => text()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{operationId};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    "CHECK (op_kind IN ('insert','patch','delete'))",
    ("CHECK (state IN "
        "('pending','in_flight','acknowledged','terminal_conflict'))"),
    'CHECK (group_index >= 0 AND group_index < group_count)',
  ];
}

/// Account/remote-profile link. Wire envelopes use `remote_profile_id`; local
/// repositories keep the existing local `profile_id`.
@DataClassName('SyncProfileLinkRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_sync_links_local '
  'ON sync_profile_links (local_profile_id, backend)',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_sync_links_remote '
  'ON sync_profile_links (backend, owner_user_id, remote_profile_id)',
)
class SyncProfileLinks extends Table {
  TextColumn get localProfileId => text()();
  TextColumn get backend => text()();
  TextColumn get ownerUserId => text()();
  TextColumn get remoteProfileId => text()();
  TextColumn get state => text()();
  TextColumn get accountFingerprint => text().nullable()();
  IntColumn get linkedAtUtc => integer().nullable()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{
    localProfileId,
    backend,
  };

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (local_profile_id) REFERENCES profiles (id)',
  ];
}

/// Database-global replication manifest. Protocol code is generated/validated
/// against this registry. Not profile-scoped.
@DataClassName('ReplicationManifestRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_replication_manifest '
  'ON replication_manifest (protocol_version, entity_type, field)',
)
class ReplicationManifest extends Table {
  IntColumn get protocolVersion => integer()();
  TextColumn get entityType => text()();
  TextColumn get field => text()();
  TextColumn get replicationClass => text()();
  TextColumn get transform => text().nullable()();
  TextColumn get tombstonePolicy => text().nullable()();
  IntColumn get introducedVersion => integer()();
  IntColumn get retiredVersion => integer().nullable()();

  @override
  List<String> get customConstraints => <String>[
    ("CHECK (replication_class IN "
        "('replicated','local_only','server_only'))"),
  ];
}

/// Per-backend pull/push cursor and bootstrap state.
@DataClassName('SyncCursorRow')
class SyncCursors extends Table {
  TextColumn get profileId => text()();
  TextColumn get backend => text()();
  TextColumn get deviceId => text().nullable()();
  IntColumn get epoch => integer()();
  TextColumn get cursor => text().nullable()();
  IntColumn get serverSeq => integer().nullable()();
  TextColumn get bootstrapGeneration => text().nullable()();
  TextColumn get bootstrapState => text().nullable()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{profileId, backend};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
  ];
}

/// Durable, pullable conflict artifacts preserved until resolved plus
/// retention expiry.
@DataClassName('SyncConflictRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_sync_conflicts_artifact '
  'ON sync_conflicts (profile_id, remote_artifact_id)',
)
@TableIndex(
  name: 'ix_sync_conflicts_open',
  columns: {#profileId, #status, #createdAtUtc},
)
@TableIndex(
  name: 'ix_sync_conflicts_entity',
  columns: {#profileId, #entityType, #entityId},
)
class SyncConflicts extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get remoteArtifactId => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get fields => text()();
  TextColumn get baseSnapshot => text().nullable()();
  TextColumn get localSnapshot => text().nullable()();
  TextColumn get remoteSnapshot => text().nullable()();
  TextColumn get policy => text()();
  TextColumn get status => text()();
  TextColumn get resolution => text().nullable()();
  IntColumn get retainedUntilUtc => integer().nullable()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get resolvedAtUtc => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    "CHECK (status IN ('open','resolved'))",
  ];
}

/// Idempotent applied-operation dedupe for inbound sync.
@DataClassName('AppliedOperationRow')
class AppliedOperations extends Table {
  TextColumn get profileId => text()();
  TextColumn get backend => text()();
  TextColumn get operationId => text()();
  TextColumn get changeId => text()();
  TextColumn get checksum => text()();
  IntColumn get appliedAtUtc => integer()();
  IntColumn get epoch => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{
    profileId,
    backend,
    operationId,
  };

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
  ];
}

/// Reproducible derived-aggregate cache keyed by policy version and source
/// commit watermark.
@DataClassName('AggregateCacheRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX ux_aggregate_cache_key '
  'ON aggregate_cache (profile_id, cache_key)',
)
class AggregateCache extends Table {
  TextColumn get profileId => text()();
  TextColumn get cacheKey => text()();
  TextColumn get metric => text()();
  TextColumn get rangeHash => text()();
  TextColumn get filterHash => text()();
  IntColumn get policyVersion => integer()();
  IntColumn get sourceCommitSeq => integer()();
  TextColumn get value => text()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{profileId, cacheKey};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
  ];
}

/// Durable file-operation journal for managed encrypted files (data-model §3).
///
/// Every staged import and every deletion is journaled before the filesystem
/// mutation so a crash leaves a restart-safe cleanup record. Hard purge is
/// blocked while an owning entity still has a non-terminal file operation
/// (R-GEN-003, R-NOTE-006). `owner_*` are nullable because startup cleanup and
/// generic staging may exist before an attachment row is published.
@DataClassName('FileJournalRow')
@TableIndex(
  name: 'ix_file_journal_state',
  columns: {#profileId, #state, #updatedAtUtc},
)
@TableIndex(
  name: 'ix_file_journal_owner',
  columns: {#profileId, #ownerEntityType, #ownerEntityId},
)
class FileJournal extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text()();
  TextColumn get ownerEntityType => text().nullable()();
  TextColumn get ownerEntityId => text().nullable()();
  TextColumn get operation => text()();
  TextColumn get stagedPathToken => text().nullable()();
  TextColumn get finalPathToken => text().nullable()();
  TextColumn get expectedHash => text().nullable()();
  IntColumn get expectedBytes => integer().nullable()();
  TextColumn get state => text()();
  IntColumn get attempts => integer().withDefault(const Constant<int>(0))();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (profile_id) REFERENCES profiles (id)',
    "CHECK (operation IN ('import','delete'))",
    ("CHECK (state IN "
        "('pending','in_progress','done','failed','cleaned'))"),
  ];
}

/// Singleton-per-generation migration/cipher/build bookkeeping. The `id = 1`
/// CHECK keeps exactly one row per generation.
@DataClassName('SchemaMetadataRow')
class SchemaMetadata extends Table {
  IntColumn get id => integer().withDefault(const Constant<int>(1))();
  IntColumn get schemaVersion => integer()();
  TextColumn get cipherVersion => text()();
  TextColumn get buildId => text()();
  TextColumn get generationId => text()();
  TextColumn get migrationState => text()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};

  @override
  List<String> get customConstraints => <String>['CHECK (id = 1)'];
}
