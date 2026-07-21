-- Forge protocol-v2 sync backend — join fitness records to replication.
--
-- Task 12.1 (R-FIT-001, R-FIT-002, R-FIT-003, R-SYNC-002, R-SYNC-003,
-- R-SYNC-004, NFR-REL-003, NFR-SEC-002). The fitness entities (workout
-- templates/exercises, workout sessions/exercise logs/set logs, body
-- measurements, water events) were implemented LOCAL-ONLY in Wave 9. This
-- migration extends the server entity allowlist so they are accepted by the
-- entity-generic push/pull RPCs from 0002.
--
-- The server is intentionally entity-generic: it owns only accepted
-- replication state (sequencing, epochs, row/field versions, tombstones,
-- conflicts, the ordered change feed) and never interprets a feature payload.
-- Joining fitness therefore needs NO new tables, RLS policies, RPCs, or grants
-- — the owner-scoped RLS and RPC-only write path in 0001/0002 already cover
-- every allowlisted entity type uniformly. Adding the entity types to the
-- allowlist is the whole server-side change (data-model.md §6).
--
-- The client replication manifest (kReplicatedV1Entities in
-- forge_replication_manifest.dart) gains the same entity types;
-- tool/sync_server_lint.py asserts the two sets are identical across every
-- migration file. The additive INSERT keeps the schema forward-only.
--
-- Apply as a migration owner, never as a client role.

begin;

-- Append the fitness entity types to the server allowlist. `on conflict do
-- nothing` keeps this migration idempotent if re-applied. The entity_type
-- vocabulary is the singular logical name used by the client manifest, the
-- outbox `entity_type`, and each typed remote applier — NOT the plural Drift
-- table name.
insert into forge.replicated_entity_types(entity_type) values
  ('workout_template'),
  ('template_exercise'),
  ('workout_session'),
  ('exercise_log'),
  ('set_log'),
  ('body_measurement'),
  ('water_event')
on conflict (entity_type) do nothing;

commit;
