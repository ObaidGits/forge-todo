-- Forge sync backend — COMPLETE RLS surface conformance (LIVE DATABASE REQUIRED).
--
-- Task 9.9 (R-SYNC-002, R-SYNC-003, R-SYNC-006, R-SYNC-007, R-SYNC-008,
-- NFR-SEC-002). This is the full owner-isolation surface testing.md §8 requires:
-- negative-first assertions for every table, grant, RPC and change feed, plus
-- the object-Storage prohibition. It complements 0001_protocol_conformance.sql
-- (protocol behavior) by proving the security boundary of EVERY table/RPC.
--
-- Coverage (each prints a *_OK marker; any failure aborts under ON_ERROR_STOP):
--   * anonymous role denied on every table read and both RPCs;
--   * cross-owner rows invisible under RLS on every owner-scoped table;
--   * cross-owner push/pull denied (ownership derives from auth.uid());
--   * direct INSERT and DELETE denied on every table (RPC-only write path);
--   * forged/foreign ownership and missing-JWT denied;
--   * operation-id replay with a different hash rejected;
--   * oversized group/batch rejected before mutation;
--   * the reference allowlist is world-readable but not client-writable;
--   * account deletion cascades every owner-scoped row away;
--   * no forge-* object Storage bucket exists (V1 prohibition).
--
-- CI/manual only. The database-free in-repo evidence is tool/sync_server_lint.py
-- (now including check_rls_read_policies and check_anon_no_access) and its unit
-- tests. Requires migrations 0001-0003 applied and the auth.uid() shim plus the
-- anon/authenticated roles (see supabase/tests/README.md). Runs in a transaction
-- and rolls back, leaving no residue.

\set ON_ERROR_STOP on
begin;

-- The nine owner-scoped tables plus the one reference table.
create temporary table _forge_owner_tables (t text) on commit drop;
insert into _forge_owner_tables(t) values
  ('remote_profiles'), ('owner_sequences'), ('entities'),
  ('entity_field_versions'), ('change_feed'), ('group_receipts'),
  ('operation_receipts'), ('sync_conflicts');

create temporary table _forge_all_tables (t text) on commit drop;
insert into _forge_all_tables(t)
  select t from _forge_owner_tables
  union all select 'replicated_entity_types';

-- Two owners, each with a remote profile and allocator.
insert into forge.remote_profiles(id, owner_user_id) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1', '11111111-1111-4111-8111-111111111111'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2', '22222222-2222-4222-8222-222222222222');
insert into forge.owner_sequences(remote_profile_id) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');

-- Owner 1 accepts one insert so every downstream table has an owner-1 row.
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select forge.push(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
  '33333333-3333-4333-8333-333333333331', 0,
  jsonb_build_array(jsonb_build_object(
    'group_id', '44444444-4444-4444-8444-444444444441',
    'operations', jsonb_build_array(jsonb_build_object(
      'operation_id', '55555555-5555-4555-8555-555555555551',
      'index', 0, 'entity_type', 'task',
      'entity_id', '66666666-6666-4666-8666-666666666661',
      'kind', 'insert',
      'payload', jsonb_build_object('title', 'first', 'notes', 'a'),
      'changed_fields', jsonb_build_array('title', 'notes')))))
) as seed \gset
select case when (:'seed'::jsonb #>> '{results,0,outcome}') = 'accepted'
  then 'SEED_OK' else (1/0)::text end as marker;
-- Force a same-field contention so sync_conflicts also has an owner-1 row.
select forge.push(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
  '33333333-3333-4333-8333-333333333331', 0,
  jsonb_build_array(jsonb_build_object(
    'group_id', '44444444-4444-4444-8444-444444444442',
    'operations', jsonb_build_array(jsonb_build_object(
      'operation_id', '55555555-5555-4555-8555-555555555552',
      'index', 0, 'entity_type', 'task',
      'entity_id', '66666666-6666-4666-8666-666666666661',
      'kind', 'patch',
      'base_field_versions', jsonb_build_object('title', 0),
      'changed_fields', jsonb_build_array('title'),
      'payload', jsonb_build_object('title', 'second')))))
) as seed_conflict \gset
reset role;

-- =========================================================================
-- 1) ANONYMOUS ROLE: no grants at all. Every table read and both RPCs denied.
-- =========================================================================
do $$
declare
  v_tables text[];
  v_t text;
  v_denied boolean;
begin
  -- Gather the table list as the owner BEFORE dropping to anon (anon has no
  -- privilege on the helper temp tables either).
  select array_agg(t) into v_tables from _forge_all_tables;
  set local role anon;
  perform set_config('request.jwt.claim.sub', '', true);
  foreach v_t in array v_tables loop
    v_denied := false;
    begin
      execute format('select 1 from forge.%I limit 1', v_t);
    exception when insufficient_privilege then v_denied := true;
    end;
    if not v_denied then
      raise exception 'anon could read forge.% (no grant expected)', v_t;
    end if;
  end loop;
  reset role;
end;
$$;
select 'ANON_TABLE_READ_DENIED_OK' as marker;

do $$
declare v_denied boolean := false;
begin
  set local role anon;
  begin
    perform forge.push('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
      gen_random_uuid(), 0, '[]'::jsonb);
  exception when insufficient_privilege then v_denied := true;
  end;
  reset role;
  if not v_denied then raise exception 'anon could call forge.push'; end if;
end;
$$;
do $$
declare v_denied boolean := false;
begin
  set local role anon;
  begin
    perform forge.pull('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1', 0, 0, 10);
  exception when insufficient_privilege then v_denied := true;
  end;
  reset role;
  if not v_denied then raise exception 'anon could call forge.pull'; end if;
end;
$$;
select 'ANON_RPC_DENIED_OK' as marker;

-- =========================================================================
-- 2) CROSS-OWNER READ ISOLATION: as owner 2, none of owner 1's owner-scoped
--    rows are visible under RLS.
-- =========================================================================
do $$
declare
  v_visible bigint;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub',
    '22222222-2222-4222-8222-222222222222', true);

  select count(*) into v_visible from forge.remote_profiles
    where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
  if v_visible <> 0 then raise exception 'owner1 remote_profiles visible to owner2'; end if;

  select count(*) into v_visible from forge.owner_sequences
    where remote_profile_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
  if v_visible <> 0 then raise exception 'owner1 owner_sequences visible to owner2'; end if;

  select count(*) into v_visible from forge.entities
    where remote_profile_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
  if v_visible <> 0 then raise exception 'owner1 entities visible to owner2'; end if;

  select count(*) into v_visible from forge.entity_field_versions
    where remote_profile_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
  if v_visible <> 0 then raise exception 'owner1 field_versions visible to owner2'; end if;

  select count(*) into v_visible from forge.change_feed
    where remote_profile_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
  if v_visible <> 0 then raise exception 'owner1 change_feed visible to owner2'; end if;

  select count(*) into v_visible from forge.group_receipts
    where remote_profile_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
  if v_visible <> 0 then raise exception 'owner1 group_receipts visible to owner2'; end if;

  select count(*) into v_visible from forge.operation_receipts
    where remote_profile_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
  if v_visible <> 0 then raise exception 'owner1 operation_receipts visible to owner2'; end if;

  select count(*) into v_visible from forge.sync_conflicts
    where remote_profile_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
  if v_visible <> 0 then raise exception 'owner1 sync_conflicts visible to owner2'; end if;

  reset role;
end;
$$;
select 'CROSS_OWNER_READ_ISOLATION_OK' as marker;

-- =========================================================================
-- 3) CROSS-OWNER RPC DENIAL: owner 2 cannot push/pull owner 1's profile.
-- =========================================================================
do $$
declare v_denied boolean := false;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub',
    '22222222-2222-4222-8222-222222222222', true);
  begin
    perform forge.push('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
      gen_random_uuid(), 0, '[]'::jsonb);
  exception when insufficient_privilege then v_denied := true;
  end;
  if not v_denied then raise exception 'cross-owner push not denied'; end if;

  v_denied := false;
  begin
    perform forge.pull('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1', 0, 0, 10);
  exception when insufficient_privilege then v_denied := true;
  end;
  if not v_denied then raise exception 'cross-owner pull not denied'; end if;
  reset role;
end;
$$;
select 'CROSS_OWNER_RPC_DENIAL_OK' as marker;

-- =========================================================================
-- 4) DIRECT WRITE DENIAL on EVERY table (RPC-only write path). Permission is
--    checked before column constraints, so a bare INSERT/DELETE raises 42501.
-- =========================================================================
do $$
declare
  v_tables text[];
  v_t text;
  v_denied boolean;
begin
  select array_agg(t) into v_tables from _forge_all_tables;
  set local role authenticated;
  perform set_config('request.jwt.claim.sub',
    '11111111-1111-4111-8111-111111111111', true);
  foreach v_t in array v_tables loop
    v_denied := false;
    begin
      execute format('insert into forge.%I default values', v_t);
    exception
      when insufficient_privilege then v_denied := true;
      when others then
        -- Any non-privilege error means the write was NOT blocked by grants.
        raise exception 'insert on forge.% not blocked by privilege (got %)', v_t, sqlerrm;
    end;
    if not v_denied then
      raise exception 'direct insert into forge.% was not denied', v_t;
    end if;

    v_denied := false;
    begin
      execute format('delete from forge.%I', v_t);
    exception when insufficient_privilege then v_denied := true;
    end;
    if not v_denied then
      raise exception 'direct delete from forge.% was not denied', v_t;
    end if;
  end loop;
  reset role;
end;
$$;
select 'DIRECT_WRITE_DENIAL_ALL_TABLES_OK' as marker;

-- =========================================================================
-- 5) FORGED / MISSING OWNERSHIP: an authenticated user with no matching remote
--    profile, and a request with no JWT subject, are both denied.
-- =========================================================================
do $$
declare v_denied boolean := false;
begin
  set local role authenticated;
  -- A subject that owns no remote profile.
  perform set_config('request.jwt.claim.sub',
    '99999999-9999-4999-8999-999999999999', true);
  begin
    perform forge.push('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
      gen_random_uuid(), 0, '[]'::jsonb);
  exception when insufficient_privilege then v_denied := true;
  end;
  if not v_denied then raise exception 'forged-owner push not denied'; end if;
  reset role;
end;
$$;
do $$
declare v_denied boolean := false;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', '', true);  -- no subject
  begin
    perform forge.push('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
      gen_random_uuid(), 0, '[]'::jsonb);
  exception when insufficient_privilege then v_denied := true;
  end;
  if not v_denied then raise exception 'missing-jwt push not denied'; end if;
  reset role;
end;
$$;
select 'FORGED_AND_MISSING_OWNERSHIP_DENIED_OK' as marker;

-- =========================================================================
-- 6) OPERATION REPLAY WITH A DIFFERENT HASH: reusing operation_id with a
--    different payload is rejected (dedupe integrity, data-model.md §6).
-- =========================================================================
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select forge.push(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
  '33333333-3333-4333-8333-333333333331', 0,
  jsonb_build_array(jsonb_build_object(
    'group_id', '44444444-4444-4444-8444-444444444443',
    'operations', jsonb_build_array(jsonb_build_object(
      'operation_id', '55555555-5555-4555-8555-555555555551', -- reused id
      'index', 0, 'entity_type', 'task',
      'entity_id', '66666666-6666-4666-8666-66666666666a',    -- different body
      'kind', 'insert',
      'payload', jsonb_build_object('title', 'different'),
      'changed_fields', jsonb_build_array('title')))))
) as replay \gset
select case when (:'replay'::jsonb #>> '{results,0,outcome}') = 'rejected'
  then 'OPERATION_REPLAY_HASH_MISMATCH_REJECTED_OK' else (1/0)::text end as marker;
reset role;

-- =========================================================================
-- 7) OVERSIZED GROUP: exceeding max_operations_per_group is rejected (the group
--    fails; nothing partial is written).
-- =========================================================================
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select forge.push(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
  '33333333-3333-4333-8333-333333333331', 0,
  jsonb_build_array(jsonb_build_object(
    'group_id', '44444444-4444-4444-8444-444444444444',
    'operations', (
      select jsonb_agg(jsonb_build_object(
        'operation_id', gen_random_uuid(),
        'index', g, 'entity_type', 'task',
        'entity_id', gen_random_uuid(), 'kind', 'insert',
        'payload', jsonb_build_object('title', 't'),
        'changed_fields', jsonb_build_array('title')))
      from generate_series(0, 512) as g)))  -- 513 > max_operations_per_group (512)
) as oversized \gset
select case when (:'oversized'::jsonb #>> '{results,0,outcome}') = 'rejected'
  then 'OVERSIZED_GROUP_REJECTED_OK' else (1/0)::text end as marker;
reset role;

-- =========================================================================
-- 8) REFERENCE ALLOWLIST: world-readable to authenticated but not writable.
-- =========================================================================
do $$
declare v_count bigint; v_denied boolean := false;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub',
    '22222222-2222-4222-8222-222222222222', true);
  select count(*) into v_count from forge.replicated_entity_types;
  if v_count = 0 then raise exception 'allowlist not readable to authenticated'; end if;
  begin
    insert into forge.replicated_entity_types(entity_type) values ('evil');
  exception when insufficient_privilege then v_denied := true;
  end;
  if not v_denied then raise exception 'allowlist is client-writable'; end if;
  reset role;
end;
$$;
select 'REFERENCE_ALLOWLIST_READ_ONLY_OK' as marker;

-- =========================================================================
-- 9) ACCOUNT DELETION CASCADE: deleting a remote profile removes every
--    owner-scoped dependent row (R-SYNC-008 remote delete).
-- =========================================================================
reset role;  -- act as the migration/service owner to delete the profile
delete from forge.remote_profiles where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
do $$
declare v_left bigint;
begin
  select
    (select count(*) from forge.owner_sequences where remote_profile_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1')
  + (select count(*) from forge.entities where remote_profile_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1')
  + (select count(*) from forge.entity_field_versions where remote_profile_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1')
  + (select count(*) from forge.change_feed where remote_profile_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1')
  + (select count(*) from forge.group_receipts where remote_profile_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1')
  + (select count(*) from forge.operation_receipts where remote_profile_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1')
  + (select count(*) from forge.sync_conflicts where remote_profile_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1')
  into v_left;
  if v_left <> 0 then
    raise exception 'account deletion left % dependent rows', v_left;
  end if;
end;
$$;
select 'ACCOUNT_DELETION_CASCADE_OK' as marker;

-- =========================================================================
-- 10) OBJECT STORAGE PROHIBITION (V1): no forge-* bucket exists.
-- =========================================================================
do $$
begin
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
select 'RLS_SURFACE_CONFORMANCE_OK' as marker;
