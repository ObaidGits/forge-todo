# Forge Core Schema — Data Dictionary (Ownership Classification)

This document records the normative ownership classification for every table
introduced by the core data platform (task 3.2). It mirrors
`lib/app/infrastructure/database/schema/ownership_classification.dart`, which is
the machine-checked source of truth. The completeness test
`test/database/schema/ownership_classification_test.dart` fails schema CI if any
table present in the database lacks exactly one class (R-GEN-002).

Ownership classes (data-model.md §1):

- **Installation root** — exactly one active local profile.
- **Direct area owner** — carries `(profile_id, life_area_id)`.
- **Inherited through strict owner** — inherits area via a composite parent FK.
- **Profile-owned, area-free** — operational / security / sync / cross-cutting.

| Table | Class | Ownership column | Notes |
|---|---|---|---|
| `profiles` | Installation root | `id` | Partial unique `is_active = 1` enforces one active local profile. |
| `devices` | Area-free | `profile_id` | Device registry per profile. |
| `life_areas` | Area-free | `profile_id` | Taxonomy; `UNIQUE(profile_id, id)` is the composite parent key for future direct-area owners. |
| `tags` | Area-free | `profile_id` | `UNIQUE(profile_id, id)` backs the composite tag FK. |
| `entity_tags` | Area-free | `profile_id` | Polymorphic; composite `(profile_id, tag_id)` FK rejects cross-profile tags; owner registry validates the entity. |
| `entity_links` | Area-free | `profile_id` | Polymorphic typed links; owner-registry validated. |
| `settings` | Area-free | `profile_id` | Typed key/value; encrypted values stored as opaque blobs. |
| `commit_log` | Area-free | `profile_id` | Monotonic `commit_seq`; PK `(profile_id, commit_seq)`. |
| `command_receipts` | Area-free | `profile_id` | PK `(profile_id, command_id)` (R-GEN-005). |
| `pending_command_journal` | Area-free | `profile_id` | Immutable canonical intent; group-unique where present. |
| `activity_events` | Area-free | `profile_id` | Append-only activity feed. |
| `projection_dirty` | Area-free | `profile_id` | Durable projection watermarks. |
| `outbox_mutations` | Area-free | `profile_id` | Transactional outbox; `idx_outbox_ready` drives the send loop. |
| `sync_profile_links` | Area-free | `local_profile_id` | Local↔remote identity link (R-SYNC-001); ownership keyed on the existing local profile. |
| `replication_manifest` | Area-free | *(database-global)* | Protocol registry; not profile-scoped. |
| `sync_cursors` | Area-free | `profile_id` | Per-backend pull/push cursor and bootstrap state. |
| `sync_conflicts` | Area-free | `profile_id` | Durable, pullable conflict artifacts. |
| `applied_operations` | Area-free | `profile_id` | Inbound idempotent dedupe. |
| `aggregate_cache` | Area-free | `profile_id` | Reproducible derived-aggregate cache. |
| `schema_metadata` | Area-free | *(database-global)* | Singleton-per-generation migration/cipher/build bookkeeping. |

`replication_manifest` and `schema_metadata` are database-global operational
records and are exempt from the profile-ownership column requirement
(`profileExemptTables`). Every other table carries a profile-ownership column
and rejects cross-profile references through composite foreign keys or the
centralized owner registry (R-GEN-002).
