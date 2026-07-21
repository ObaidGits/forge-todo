-- Forge sync backend — protocol/RLS/RPC conformance (LIVE DATABASE REQUIRED).
--
-- Task 9.2 server foundation checks. This is a psql conformance script in the
-- style of tool/probes/supabase_conformance/sql/conformance.sql. It requires a
-- live PostgreSQL/Supabase instance with the 0001-0003 migrations applied and
-- the `auth.uid()` shim available (Supabase provides it; a bare Postgres CI job
-- must define it — see supabase/tests/README.md). It runs inside a transaction
-- and rolls back, leaving no residue.
--
-- Assertions use plain SQL so they work regardless of psql variable
-- interpolation rules: a failing check evaluates `(1/0)::text` and aborts under
-- ON_ERROR_STOP. Each passing check prints an `*_OK` marker.
--
-- CI/manual only. The in-repo, database-free evidence is tool/sync_server_lint.py
-- and its unit tests. The full RLS surface suite is task 9.9; live client/server
-- compatibility is task 9.10 — this script covers the server foundation only.

\set ON_ERROR_STOP on
begin;

-- Two owners, each with one remote profile.
insert into forge.remote_profiles(id, owner_user_id) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1', '11111111-1111-4111-8111-111111111111'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2', '22222222-2222-4222-8222-222222222222');

-- Act as owner 1.
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);

-- 1) Group-atomic accept + ordered change feed + idempotent replay.
select forge.push(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
  '33333333-3333-4333-8333-333333333331',
  0,
  jsonb_build_array(jsonb_build_object(
    'group_id', '44444444-4444-4444-8444-444444444441',
    'operations', jsonb_build_array(
      jsonb_build_object(
        'operation_id', '55555555-5555-4555-8555-555555555551',
        'index', 0, 'entity_type', 'task',
        'entity_id', '66666666-6666-4666-8666-666666666661',
        'kind', 'insert',
        'payload', jsonb_build_object('title', 'first', 'notes', 'a'),
        'changed_fields', jsonb_build_array('title', 'notes'))
    )))
) as push1 \gset

select forge.push(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
  '33333333-3333-4333-8333-333333333331',
  0,
  jsonb_build_array(jsonb_build_object(
    'group_id', '44444444-4444-4444-8444-444444444441',
    'operations', jsonb_build_array(
      jsonb_build_object(
        'operation_id', '55555555-5555-4555-8555-555555555551',
        'index', 0, 'entity_type', 'task',
        'entity_id', '66666666-6666-4666-8666-666666666661',
        'kind', 'insert',
        'payload', jsonb_build_object('title', 'first', 'notes', 'a'),
        'changed_fields', jsonb_build_array('title', 'notes'))
    )))
) as push1_replay \gset

select case when (:'push1'::jsonb #>> '{results,0,outcome}') = 'accepted'
  then 'GROUP_ACCEPT_OK' else (1/0)::text end as marker;
select case when :'push1'::jsonb = :'push1_replay'::jsonb
  then 'IDEMPOTENT_REPLAY_OK' else (1/0)::text end as marker;

-- 2) Ordered pull returns the accepted change.
select forge.pull('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1', 0, 0, 100) as pull1 \gset
select case when jsonb_array_length((:'pull1'::jsonb)->'changes') >= 1
  and ((:'pull1'::jsonb) #>> '{changes,0,entity_type}') = 'task'
  then 'ORDERED_PULL_OK' else (1/0)::text end as marker;

-- 2b) Disjoint-field patch applies cleanly against a current base (no conflict).
select forge.push(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
  '33333333-3333-4333-8333-333333333331', 0,
  jsonb_build_array(jsonb_build_object(
    'group_id', '44444444-4444-4444-8444-444444444445',
    'operations', jsonb_build_array(jsonb_build_object(
      'operation_id', '55555555-5555-4555-8555-555555555561',
      'index', 0, 'entity_type', 'task',
      'entity_id', '66666666-6666-4666-8666-666666666661',
      'kind', 'patch',
      'base_field_versions', jsonb_build_object('notes', 1),
      'changed_fields', jsonb_build_array('notes'),
      'payload', jsonb_build_object('notes', 'b')))))
) as push_disjoint \gset
select case when (:'push_disjoint'::jsonb #>> '{results,0,outcome}') = 'accepted'
  then 'DISJOINT_MERGE_OK' else (1/0)::text end as marker;

-- 2c) Same-field contention against a stale base: later server acceptance wins
--     and a durable conflict artifact is created and pullable (R-SYNC-004).
select forge.push(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
  '33333333-3333-4333-8333-333333333331', 0,
  jsonb_build_array(jsonb_build_object(
    'group_id', '44444444-4444-4444-8444-444444444446',
    'operations', jsonb_build_array(jsonb_build_object(
      'operation_id', '55555555-5555-4555-8555-555555555562',
      'index', 0, 'entity_type', 'task',
      'entity_id', '66666666-6666-4666-8666-666666666661',
      'kind', 'patch',
      'base_field_versions', jsonb_build_object('notes', 1),
      'changed_fields', jsonb_build_array('notes'),
      'payload', jsonb_build_object('notes', 'c')))))
) as push_conflict \gset
select case when (:'push_conflict'::jsonb #>> '{results,0,outcome}') = 'conflict'
  and (:'push_conflict'::jsonb #>> '{results,0,conflict_artifact_id}') is not null
  then 'SAME_FIELD_CONFLICT_OUTCOME_OK' else (1/0)::text end as marker;

-- The winner (later acceptance) is 'c'; the artifact preserves the loser 'b'.
select forge.pull('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1', 0, 0, 100) as pull2 \gset
select case when jsonb_array_length((:'pull2'::jsonb)->'conflicts') >= 1
  and ((:'pull2'::jsonb) #>> '{conflicts,0,fields,0}') = 'notes'
  and ((:'pull2'::jsonb) #>> '{conflicts,0,local_value,notes}') = 'c'
  and ((:'pull2'::jsonb) #>> '{conflicts,0,remote_value,notes}') = 'b'
  then 'DURABLE_CONFLICT_PULLABLE_OK' else (1/0)::text end as marker;

-- 3) Group-atomic REJECT: an unresolved parent reference rejects the whole
--    group and writes nothing (no partial rows, no server_seq gap).
select forge.push(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
  '33333333-3333-4333-8333-333333333331',
  0,
  jsonb_build_array(jsonb_build_object(
    'group_id', '44444444-4444-4444-8444-444444444442',
    'operations', jsonb_build_array(
      jsonb_build_object(
        'operation_id', '55555555-5555-4555-8555-555555555552',
        'index', 0, 'entity_type', 'task_occurrence',
        'entity_id', '66666666-6666-4666-8666-666666666662',
        'kind', 'insert',
        'parent_entity_id', '99999999-9999-4999-8999-999999999999',
        'payload', jsonb_build_object('due', 'x'),
        'changed_fields', jsonb_build_array('due'))
    )))
) as push_reject \gset
select case when (:'push_reject'::jsonb #>> '{results,0,outcome}') = 'rejected'
  then 'GROUP_REJECT_OUTCOME_OK' else (1/0)::text end as marker;
do $$
begin
  if exists (select 1 from forge.entities
             where entity_id = '66666666-6666-4666-8666-666666666662') then
    raise exception 'rejected group left a partial row';
  end if;
end;
$$;
select 'GROUP_REJECT_ATOMIC_OK' as marker;

-- 4) Direct table write is denied (RPC-only write path).
do $$
declare denied boolean := false;
begin
  begin
    insert into forge.entities(remote_profile_id, entity_id, entity_type,
      snapshot_epoch, last_server_seq)
    values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
      gen_random_uuid(), 'task', 0, 1);
  exception when insufficient_privilege then denied := true;
  end;
  if not denied then raise exception 'direct write was not denied'; end if;
end;
$$;
select 'DIRECT_WRITE_DENIAL_OK' as marker;

-- 5) Cross-owner push is denied (owner derives from auth.uid()).
do $$
declare denied boolean := false;
begin
  begin
    perform forge.push('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
      gen_random_uuid(), 0, '[]'::jsonb);
  exception when insufficient_privilege then denied := true;
  end;
  if not denied then raise exception 'cross-owner push not denied'; end if;
end;
$$;
select 'CROSS_OWNER_RPC_DENIAL_OK' as marker;

-- 6) Cross-owner rows are invisible under RLS.
do $$
begin
  if exists (select 1 from forge.entities
             where remote_profile_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2') then
    raise exception 'cross-owner rows are visible under RLS';
  end if;
end;
$$;
select 'CROSS_OWNER_RLS_OK' as marker;

-- 7) Stale-epoch push is rejected before mutation.
reset role;
update forge.remote_profiles set snapshot_epoch = 5
  where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select forge.push(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
  '33333333-3333-4333-8333-333333333331',
  0,
  jsonb_build_array(jsonb_build_object(
    'group_id', '44444444-4444-4444-8444-444444444443',
    'operations', jsonb_build_array(
      jsonb_build_object(
        'operation_id', '55555555-5555-4555-8555-555555555553',
        'index', 0, 'entity_type', 'task',
        'entity_id', '66666666-6666-4666-8666-666666666663',
        'kind', 'insert', 'payload', jsonb_build_object('title', 'stale'),
        'changed_fields', jsonb_build_array('title'))
    )))
) as push_stale \gset
select case when (:'push_stale'::jsonb #>> '{results,0,outcome}') = 'stale_epoch'
  then 'STALE_EPOCH_OUTCOME_OK' else (1/0)::text end as marker;
do $$
begin
  if exists (select 1 from forge.entities
             where entity_id = '66666666-6666-4666-8666-666666666663') then
    raise exception 'stale-epoch push mutated state';
  end if;
end;
$$;
select 'STALE_EPOCH_ATOMIC_OK' as marker;

-- 7b) Fitness parent-before-child accept (task 12.1): a workout_session parent
--     and its exercise_log child in one group are accepted in order, proving
--     the fitness entity types are allowlisted and the generic parent-before-
--     child topology check covers them (R-FIT-001, R-SYNC-002, R-SYNC-004).
--     The server epoch is now 5 (section 7 advanced it), so push at epoch 5.
select forge.push(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
  '33333333-3333-4333-8333-333333333331',
  5,
  jsonb_build_array(jsonb_build_object(
    'group_id', '44444444-4444-4444-8444-444444444447',
    'operations', jsonb_build_array(
      jsonb_build_object(
        'operation_id', '55555555-5555-4555-8555-555555555571',
        'index', 0, 'entity_type', 'workout_session',
        'entity_id', '66666666-6666-4666-8666-666666666671',
        'kind', 'insert',
        'payload', jsonb_build_object('title', 'Morning lift'),
        'changed_fields', jsonb_build_array('title')),
      jsonb_build_object(
        'operation_id', '55555555-5555-4555-8555-555555555572',
        'index', 1, 'entity_type', 'exercise_log',
        'entity_id', '66666666-6666-4666-8666-666666666672',
        'kind', 'insert',
        'parent_entity_id', '66666666-6666-4666-8666-666666666671',
        'payload', jsonb_build_object('name', 'Squat', 'rank', 'm'),
        'changed_fields', jsonb_build_array('name', 'rank')))))
) as push_fitness \gset
select case when (:'push_fitness'::jsonb #>> '{results,0,outcome}') = 'accepted'
  then 'FITNESS_PARENT_BEFORE_CHILD_OK' else (1/0)::text end as marker;

reset role;

-- 8) No Forge object Storage bucket exists (V1 prohibition).
do $$
begin
  -- Nested guard so the storage.buckets reference is only planned when the
  -- schema exists (bare-Postgres CI has no storage service).
  if to_regclass('storage.buckets') is not null then
    if exists (
      select 1 from storage.buckets where id like 'forge-%' or name like 'forge-%'
    ) then
      raise exception 'a forge-* object Storage bucket exists (prohibited in V1)';
    end if;
  end if;
end;
$$;
select 'NO_REMOTE_ATTACHMENT_STORAGE_OK' as marker;

rollback;
select 'SQL_CONFORMANCE_OK' as marker;
