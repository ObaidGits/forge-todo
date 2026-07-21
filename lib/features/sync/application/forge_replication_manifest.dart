/// The Forge V1 protocol-v2 replication manifest (R-SYNC-002, data-model.md §3).
///
/// This is the client-side authority that classifies every entity as
/// replicated, local-only, or server-only. It is entity-granular with explicit
/// per-field overrides where a replicated entity carries a local-only column.
/// The manifest deliberately does NOT replicate the ordinary `profiles` table:
/// remote profile metadata is a special projection onto the existing local
/// profile (`profile_metadata`).
///
/// Wave 8 registered the MVP domain entities. Wave 11 (task 12.1) joins the
/// fitness records to replication by adding the workout template/exercise,
/// workout session/exercise-log/set-log, body-measurement, and water-event
/// entities with per-field overrides preserving entered units and keeping the
/// derived canonical amounts device-local.
library;

import 'package:forge/features/sync/domain/replication_manifest.dart';

/// The entity types replicated at protocol v2 in V1 (data-model.md §3
/// "Replicated V1 domain entities").
const List<String> kReplicatedV1Entities = <String>[
  'profile_metadata',
  'life_area',
  'tag',
  'entity_tag',
  'entity_link',
  'task',
  'recurrence_rule',
  'task_occurrence',
  'task_occurrence_event',
  'reminder',
  'goal',
  'milestone',
  'roadmap',
  'roadmap_section',
  'roadmap_topic',
  'checklist_item',
  'course',
  'learning_item',
  'study_session',
  'study_session_event',
  'habit',
  'habit_schedule',
  'habit_occurrence',
  'habit_checkin',
  'habit_pause',
  'note',
  'note_link',
  'planning_period',
  'planning_entry',
  'planning_close_event',
  'planning_close_item',
  'planning_close_adjustment',
  'focus_event',
  // Fitness records joined to replication in Wave 11 (task 12.1; R-FIT-001,
  // R-FIT-002, R-FIT-003; data-model.md §3 "fitness records"). The workout
  // template→exercise and session→exercise-log→set-log hierarchies replicate
  // parent-before-child; body measurements and water events are top-level
  // direct-area owners. Water EVENTS replicate as ordinary fitness records —
  // only the disabled-by-default water-tracking enable preference stays
  // device-local (settings_device_private), per R-FIT-003.
  'workout_template',
  'template_exercise',
  'workout_session',
  'exercise_log',
  'set_log',
  'body_measurement',
  'water_event',
  'settings_portable',
];

/// Entities that never leave the device (data-model.md §3 "Local-only
/// fields/entities"). Serializing any of these is a manifest violation.
const List<String> kLocalOnlyV1Entities = <String>[
  'profiles',
  'devices',
  'note_draft',
  'attachment',
  'file_journal',
  'widget_snapshot',
  'key_metadata',
  'settings_device_private',
  'command_receipt',
  'pending_command_journal',
  'aggregate_cache',
  'search_document',
  'fts_rowid',
  'projection_dirty',
  'schema_metadata',
  'sync_profile_link',
];

/// Server-only entities: sequence/epoch/field-version/RLS data owned by the
/// server and never authored by the client.
const List<String> kServerOnlyV1Entities = <String>[
  'server_change_feed',
  'server_field_version',
];

/// Builds the immutable Forge V1 replication manifest.
ReplicationManifest buildForgeReplicationManifestV1() {
  final List<ManifestEntry> entries = <ManifestEntry>[
    for (final String entity in kReplicatedV1Entities)
      ManifestEntry(
        entityType: entity,
        field: kManifestFieldWildcard,
        replicationClass: ReplicationClass.replicated,
        introducedVersion: 2,
      ),
    for (final String entity in kLocalOnlyV1Entities)
      ManifestEntry(
        entityType: entity,
        field: kManifestFieldWildcard,
        replicationClass: ReplicationClass.localOnly,
        introducedVersion: 2,
      ),
    for (final String entity in kServerOnlyV1Entities)
      ManifestEntry(
        entityType: entity,
        field: kManifestFieldWildcard,
        replicationClass: ReplicationClass.serverOnly,
        introducedVersion: 2,
      ),
    // Per-field overrides: replicated entities that carry a local-only column.
    // A note's reconstructable content hash and any device-local scheduler
    // token never cross the wire even though the owning entity is replicated.
    ManifestEntry(
      entityType: 'note',
      field: 'content_hash',
      replicationClass: ReplicationClass.localOnly,
      introducedVersion: 2,
    ),
    ManifestEntry(
      entityType: 'reminder',
      field: 'delivery_token',
      replicationClass: ReplicationClass.localOnly,
      introducedVersion: 2,
    ),
    // Server-assigned authority fields present on replicated rows.
    ManifestEntry(
      entityType: 'task',
      field: 'server_version',
      replicationClass: ReplicationClass.serverOnly,
      introducedVersion: 2,
    ),
    // Fitness per-field overrides (task 12.1; R-FIT-002, R-FIT-003).
    //
    // Unit preservation: the ENTERED value/unit are authoritative and cross the
    // wire, while the canonical `*_scaled` integer amount is a purely derived
    // column recomputed deterministically from the entered value/unit by the
    // typed applier. Replicating only the entered pair keeps the entered value
    // from drifting through rounding and avoids shipping a redundant derived
    // field (data-model.md §3 "Local-only fields").
    ManifestEntry(
      entityType: 'set_log',
      field: 'weight_scaled',
      replicationClass: ReplicationClass.localOnly,
      introducedVersion: 2,
    ),
    ManifestEntry(
      entityType: 'set_log',
      field: 'distance_scaled',
      replicationClass: ReplicationClass.localOnly,
      introducedVersion: 2,
    ),
    ManifestEntry(
      entityType: 'body_measurement',
      field: 'value_scaled',
      replicationClass: ReplicationClass.localOnly,
      introducedVersion: 2,
    ),
    ManifestEntry(
      entityType: 'water_event',
      field: 'amount_scaled',
      replicationClass: ReplicationClass.localOnly,
      introducedVersion: 2,
    ),
    // The local soft-delete marker is device-local; a replicated delete is a
    // tombstone operation, not a mirrored `deleted_at_utc` column.
    for (final String entity in <String>[
      'workout_template',
      'workout_session',
      'body_measurement',
      'water_event',
    ])
      ManifestEntry(
        entityType: entity,
        field: 'deleted_at_utc',
        replicationClass: ReplicationClass.localOnly,
        introducedVersion: 2,
      ),
  ];
  return ReplicationManifest(entries, protocolVersion: 2);
}
