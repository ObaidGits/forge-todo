-- Forge protocol-v2 sync backend — schema, sequencing, epochs, RLS, grants.
--
-- Task 9.2 (R-SYNC-003, R-SYNC-004, NFR-SEC-002). This is the server side of
-- the protocol whose client contracts landed in task 9.1
-- (lib/features/sync/**). It is intentionally entity-generic: PostgreSQL owns
-- only server-accepted replication state (per-owner sequencing, epochs, row and
-- per-field versions, tombstones, durable conflict artifacts and one ordered
-- change feed). It never interprets a feature's payload — the client's typed
-- appliers do that — so the server stays stable as features evolve.
--
-- Authority model (data-model.md §6): the active local Drift generation is the
-- client source of truth and includes unaccepted local work; this database owns
-- only accepted state. Server acceptance order resolves conflicts; client
-- timestamps are audit data only.
--
-- Security model (NFR-SEC-002): every table forces RLS restricting each row to
-- its owner (auth.uid()); the only sanctioned write path is the reviewed
-- SECURITY DEFINER RPCs in 0002; broad direct writes are denied. Service-role
-- credentials are server-only and never ship in clients.
--
-- Apply as a migration owner, never as a client role.

begin;

create schema if not exists forge;
revoke all on schema forge from public;
grant usage on schema forge to authenticated;

-- ---------------------------------------------------------------------------
-- Remote profiles: one authenticated account owns at most one Forge profile in
-- V1 (R-SYNC-001). The remote profile id is immutable and equals some device's
-- local profile id; client entity ids are never rekeyed.
-- ---------------------------------------------------------------------------
create table forge.remote_profiles (
  id uuid primary key,
  owner_user_id uuid not null unique,
  protocol_version integer not null default 2 check (protocol_version = 2),
  -- Monotonic snapshot epoch. A retention purge increments this; a device on an
  -- earlier epoch may pull/bootstrap but cannot push first (R-SYNC-003).
  snapshot_epoch bigint not null default 0 check (snapshot_epoch >= 0),
  created_at timestamptz not null default statement_timestamp(),
  constraint remote_profile_id_nonzero
    check (id <> '00000000-0000-0000-0000-000000000000')
);

comment on table forge.remote_profiles is
  'One remote Forge profile per authenticated owner (R-SYNC-001). Immutable id; owner derives from auth.uid().';

-- ---------------------------------------------------------------------------
-- Per-owner gap-free sequence allocator. A single row per owner is locked
-- FOR UPDATE inside the push transaction to produce contiguous accepted
-- ordering (data-model.md §6 "One per-owner sequence allocator and transaction
-- produces gap-free accepted ordering"). A plain identity/sequence would leave
-- gaps on rollback, which the contiguous pull cursor forbids.
-- ---------------------------------------------------------------------------
create table forge.owner_sequences (
  remote_profile_id uuid primary key
    references forge.remote_profiles(id) on delete cascade,
  next_server_seq bigint not null default 1 check (next_server_seq >= 1)
);

comment on table forge.owner_sequences is
  'Per-owner gap-free server_seq allocator; locked FOR UPDATE within the push transaction.';

-- ---------------------------------------------------------------------------
-- Entity allowlist: the replicated protocol-v2 entity types. Mirrors the
-- client manifest (kReplicatedV1Entities in forge_replication_manifest.dart);
-- tool/sync_server_lint.py asserts the two sets are identical. The server
-- rejects any operation whose entity_type is not allowlisted before mutation.
-- ---------------------------------------------------------------------------
create table forge.replicated_entity_types (
  entity_type text primary key,
  introduced_protocol_version integer not null default 2
);

insert into forge.replicated_entity_types(entity_type) values
  ('profile_metadata'),
  ('life_area'),
  ('tag'),
  ('entity_tag'),
  ('entity_link'),
  ('task'),
  ('recurrence_rule'),
  ('task_occurrence'),
  ('task_occurrence_event'),
  ('reminder'),
  ('goal'),
  ('milestone'),
  ('roadmap'),
  ('roadmap_section'),
  ('roadmap_topic'),
  ('checklist_item'),
  ('course'),
  ('learning_item'),
  ('study_session'),
  ('study_session_event'),
  ('habit'),
  ('habit_schedule'),
  ('habit_occurrence'),
  ('habit_checkin'),
  ('habit_pause'),
  ('note'),
  ('note_link'),
  ('planning_period'),
  ('planning_entry'),
  ('planning_close_event'),
  ('planning_close_item'),
  ('planning_close_adjustment'),
  ('focus_event'),
  ('settings_portable');

comment on table forge.replicated_entity_types is
  'Server allowlist of replicated entity types; must equal the client manifest (task 9.1).';

-- ---------------------------------------------------------------------------
-- Accepted entity rows. Server-owned authority state per (owner, entity_id):
-- row version, tombstone, latest replicated payload and parent reference.
-- The ordinary local `profiles` table is never a replicated entity — remote
-- profile metadata is the special `profile_metadata` projection (R-SYNC-001).
-- ---------------------------------------------------------------------------
create table forge.entities (
  remote_profile_id uuid not null references forge.remote_profiles(id) on delete cascade,
  entity_id uuid not null,
  entity_type text not null references forge.replicated_entity_types(entity_type),
  server_version bigint not null default 1 check (server_version >= 1),
  tombstone boolean not null default false,
  parent_entity_id uuid,
  payload jsonb not null default '{}'::jsonb,
  snapshot_epoch bigint not null check (snapshot_epoch >= 0),
  -- server_seq of the change that last mutated this row.
  last_server_seq bigint not null check (last_server_seq >= 1),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  primary key (remote_profile_id, entity_id),
  constraint entities_profile_never_ordinary
    check (entity_type <> 'profiles')
);

create index entities_parent_idx
  on forge.entities (remote_profile_id, parent_entity_id)
  where parent_entity_id is not null;

comment on table forge.entities is
  'Accepted entity rows with server row version, tombstone and latest replicated payload.';

-- Per-field versions sufficient for disjoint-field merge (R-SYNC-004). Each
-- field carries (version, last_operation_id).
create table forge.entity_field_versions (
  remote_profile_id uuid not null,
  entity_id uuid not null,
  field text not null,
  version bigint not null check (version >= 1),
  last_operation_id uuid not null,
  primary key (remote_profile_id, entity_id, field),
  foreign key (remote_profile_id, entity_id)
    references forge.entities(remote_profile_id, entity_id) on delete cascade
);

comment on table forge.entity_field_versions is
  'Per-field (version,last_operation_id) enabling disjoint-field merge (R-SYNC-004).';

-- ---------------------------------------------------------------------------
-- Ordered change feed: the authoritative per-owner pull stream ordered by
-- server_seq (R-SYNC-003). One accepted group appends a contiguous block, in
-- parent-before-child operation order. This is the cursor stream clients track.
-- ---------------------------------------------------------------------------
create table forge.change_feed (
  remote_profile_id uuid not null references forge.remote_profiles(id) on delete cascade,
  server_seq bigint not null,
  snapshot_epoch bigint not null check (snapshot_epoch >= 0),
  entity_type text not null,
  entity_id uuid not null,
  kind text not null check (kind in ('insert', 'patch', 'delete')),
  server_version bigint not null check (server_version >= 1),
  tombstone boolean not null default false,
  parent_entity_id uuid,
  payload jsonb not null default '{}'::jsonb,
  field_versions jsonb not null default '{}'::jsonb,
  group_id uuid not null,
  committed_at timestamptz not null default statement_timestamp(),
  primary key (remote_profile_id, server_seq)
);

create index change_feed_epoch_seq_idx
  on forge.change_feed (remote_profile_id, snapshot_epoch, server_seq);

comment on table forge.change_feed is
  'Authoritative ordered pull stream by server_seq; hint-only Realtime mirrors it.';

-- ---------------------------------------------------------------------------
-- Group receipts: idempotent dedupe of an accepted/rejected semantic group by
-- (owner, group_id). A replay with the same request hash returns the stored
-- result; a reused id with a different hash is rejected. Receipts survive at
-- least the supported 180-day offline window (data-model.md §6/§8).
-- ---------------------------------------------------------------------------
create table forge.group_receipts (
  remote_profile_id uuid not null references forge.remote_profiles(id) on delete cascade,
  group_id uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  result jsonb not null,
  server_seq_start bigint,
  server_seq_end bigint,
  committed_at timestamptz not null default statement_timestamp(),
  primary key (remote_profile_id, group_id)
);

comment on table forge.group_receipts is
  'Idempotent per-group dedupe keyed by (owner, group_id) with stable result and request hash.';

-- Operation receipts: dedupe individual operations by (owner, operation_id) for
-- cross-group idempotence (data-model.md §6 "deduplicates by (owner,operation_id)").
create table forge.operation_receipts (
  remote_profile_id uuid not null references forge.remote_profiles(id) on delete cascade,
  operation_id uuid not null,
  group_id uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  committed_at timestamptz not null default statement_timestamp(),
  primary key (remote_profile_id, operation_id)
);

comment on table forge.operation_receipts is
  'Per-operation dedupe keyed by (owner, operation_id); same id/different hash is rejected.';

-- ---------------------------------------------------------------------------
-- Durable conflict artifacts (R-SYNC-004). A same-field contention preserves
-- the exact base/local/remote values and is pullable and durable until resolved
-- plus retention expiry. Task 9.3 layers typed/entity policies on top; this
-- table is the generic durable store the server writes atomically with the
-- accepting group.
-- ---------------------------------------------------------------------------
create table forge.sync_conflicts (
  remote_profile_id uuid not null references forge.remote_profiles(id) on delete cascade,
  artifact_id uuid not null,
  entity_type text not null,
  entity_id uuid not null,
  fields jsonb not null default '[]'::jsonb,
  base_value jsonb,
  local_value jsonb,
  remote_value jsonb,
  policy text not null,
  status text not null default 'open' check (status in ('open', 'resolved')),
  resolution jsonb,
  created_server_seq bigint not null,
  snapshot_epoch bigint not null check (snapshot_epoch >= 0),
  created_at timestamptz not null default statement_timestamp(),
  resolved_at timestamptz,
  primary key (remote_profile_id, artifact_id)
);

create index sync_conflicts_open_idx
  on forge.sync_conflicts (remote_profile_id, created_server_seq)
  where status = 'open';

comment on table forge.sync_conflicts is
  'Durable, pullable conflict artifacts preserving exact base/local/remote values (R-SYNC-004).';

-- ---------------------------------------------------------------------------
-- Row Level Security. Every table forces RLS. Reads are owner-scoped; there are
-- NO write policies, so every direct INSERT/UPDATE/DELETE by the authenticated
-- role is denied — mutation happens only through the SECURITY DEFINER RPCs in
-- 0002 (NFR-SEC-002).
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'remote_profiles', 'owner_sequences', 'replicated_entity_types',
    'entities', 'entity_field_versions', 'change_feed', 'group_receipts',
    'operation_receipts', 'sync_conflicts'
  ] loop
    execute format('alter table forge.%I enable row level security', t);
    execute format('alter table forge.%I force row level security', t);
  end loop;
end;
$$;

-- Owner-scoped read policies. A row is visible only to its owner (auth.uid()).
create policy remote_profiles_owner_read on forge.remote_profiles
  for select to authenticated
  using (owner_user_id = (select auth.uid()));

create policy owner_sequences_owner_read on forge.owner_sequences
  for select to authenticated
  using (exists (
    select 1 from forge.remote_profiles p
    where p.id = owner_sequences.remote_profile_id
      and p.owner_user_id = (select auth.uid())));

create policy entities_owner_read on forge.entities
  for select to authenticated
  using (exists (
    select 1 from forge.remote_profiles p
    where p.id = entities.remote_profile_id
      and p.owner_user_id = (select auth.uid())));

create policy field_versions_owner_read on forge.entity_field_versions
  for select to authenticated
  using (exists (
    select 1 from forge.remote_profiles p
    where p.id = entity_field_versions.remote_profile_id
      and p.owner_user_id = (select auth.uid())));

create policy change_feed_owner_read on forge.change_feed
  for select to authenticated
  using (exists (
    select 1 from forge.remote_profiles p
    where p.id = change_feed.remote_profile_id
      and p.owner_user_id = (select auth.uid())));

create policy group_receipts_owner_read on forge.group_receipts
  for select to authenticated
  using (exists (
    select 1 from forge.remote_profiles p
    where p.id = group_receipts.remote_profile_id
      and p.owner_user_id = (select auth.uid())));

create policy operation_receipts_owner_read on forge.operation_receipts
  for select to authenticated
  using (exists (
    select 1 from forge.remote_profiles p
    where p.id = operation_receipts.remote_profile_id
      and p.owner_user_id = (select auth.uid())));

create policy sync_conflicts_owner_read on forge.sync_conflicts
  for select to authenticated
  using (exists (
    select 1 from forge.remote_profiles p
    where p.id = sync_conflicts.remote_profile_id
      and p.owner_user_id = (select auth.uid())));

-- The allowlist is world-readable reference data for the owner role (no owner
-- column); it is still RLS-forced and select-only.
create policy replicated_entity_types_read on forge.replicated_entity_types
  for select to authenticated using (true);

-- ---------------------------------------------------------------------------
-- Grants. Deny everything, then grant SELECT only (reads). No table-level
-- INSERT/UPDATE/DELETE is granted to clients; writes flow through RPCs (0002).
-- anon has no access at all.
-- ---------------------------------------------------------------------------
revoke all on all tables in schema forge from public, anon, authenticated;
revoke all on all sequences in schema forge from public, anon, authenticated;

grant select on
  forge.remote_profiles,
  forge.owner_sequences,
  forge.replicated_entity_types,
  forge.entities,
  forge.entity_field_versions,
  forge.change_feed,
  forge.group_receipts,
  forge.operation_receipts,
  forge.sync_conflicts
to authenticated;

commit;
