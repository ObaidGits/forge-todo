-- Forge protocol-v2 sync backend — RPC write/read surfaces and limits.
--
-- Task 9.2 (R-SYNC-003, R-SYNC-004, NFR-SEC-002). These SECURITY DEFINER
-- functions are the ONLY sanctioned mutation path (broad direct writes are
-- denied by RLS in 0001). They derive the authenticated owner from auth.uid()
-- and validate the request's remote_profile_id against that owner rather than
-- trusting any client-supplied ownership.
--
-- Wire vocabulary and limits mirror lib/features/sync/application/
-- sync_server_contract.dart; tool/sync_server_lint.py asserts they match.
--
-- Apply as a migration owner, never as a client role.

begin;

-- Hashing and UUIDs use core functions (sha256/convert_to/encode/
-- gen_random_uuid, all in pg_catalog on PostgreSQL 13+) so the SECURITY DEFINER
-- functions keep a tight pinned search_path without depending on where an
-- extension like pgcrypto happens to be installed.

-- ---------------------------------------------------------------------------
-- Protocol limits. These values MUST equal SyncProtocolLimits in the Dart
-- contract. The lint tool cross-checks the numeric literals.
-- ---------------------------------------------------------------------------
create or replace function forge.protocol_limits()
returns jsonb
language sql
immutable
set search_path = pg_catalog
as $$
  select jsonb_build_object(
    'max_groups_per_push', 128,
    'max_operations_per_group', 512,
    'max_operations_per_push', 2048,
    'max_changes_per_pull_page', 512,
    'max_operation_payload_bytes', 262144,
    'max_push_request_bytes', 4194304,
    'protocol_version', 2
  );
$$;

comment on function forge.protocol_limits() is
  'Canonical protocol-v2 limits; must equal SyncProtocolLimits (task 9.1/9.2).';

-- ---------------------------------------------------------------------------
-- Owner resolution helper. Raises insufficient_privilege (42501) unless the
-- authenticated user owns the remote profile. Never trusts client-supplied
-- ownership (NFR-SEC-002).
-- ---------------------------------------------------------------------------
create or replace function forge._require_owner(p_remote_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, forge
as $$
declare
  v_owner uuid;
  v_auth uuid := auth.uid();
begin
  if v_auth is null then
    raise exception using errcode = '42501', message = 'authentication required';
  end if;
  select owner_user_id into v_owner
    from forge.remote_profiles where id = p_remote_profile_id;
  if v_owner is null or v_owner <> v_auth then
    raise exception using errcode = '42501',
      message = 'remote profile ownership denied';
  end if;
end;
$$;

-- Builds the current per-field version map for one entity as
-- {field: {version, last_operation_id}}.
create or replace function forge._field_versions_json(
  p_remote_profile_id uuid,
  p_entity_id uuid
) returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, forge
as $$
  select coalesce(jsonb_object_agg(
    fv.field,
    jsonb_build_object('version', fv.version, 'last_operation_id', fv.last_operation_id)
  ), '{}'::jsonb)
  from forge.entity_field_versions fv
  where fv.remote_profile_id = p_remote_profile_id
    and fv.entity_id = p_entity_id;
$$;

-- ---------------------------------------------------------------------------
-- Applies a single validated operation, allocating a server_seq, mutating the
-- entity + field versions, writing the change-feed row, and recording any
-- durable conflict artifact. Runs inside the per-group subtransaction of
-- forge.push. Raises to reject the whole group (data-model.md §6 all-or-reject).
-- ---------------------------------------------------------------------------
create or replace function forge._apply_operation(
  p_remote_profile_id uuid,
  p_epoch bigint,
  p_group_id uuid,
  p_op jsonb
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, forge
as $$
declare
  v_operation_id uuid := (p_op->>'operation_id')::uuid;
  v_entity_type text := p_op->>'entity_type';
  v_entity_id uuid := (p_op->>'entity_id')::uuid;
  v_kind text := p_op->>'kind';
  v_parent uuid := nullif(p_op->>'parent_entity_id', '')::uuid;
  v_payload jsonb := coalesce(p_op->'payload', '{}'::jsonb);
  v_changed jsonb := coalesce(p_op->'changed_fields', '[]'::jsonb);
  v_base_fv jsonb := coalesce(p_op->'base_field_versions', '{}'::jsonb);
  v_limits jsonb := forge.protocol_limits();
  v_seq bigint;
  v_exists boolean;
  v_tombstone boolean;
  v_server_version bigint;
  v_field text;
  v_new_value jsonb;
  v_cur_ver bigint;
  v_base_ver bigint;
  v_prior_value jsonb;
  v_conflict_fields jsonb := '[]'::jsonb;
  v_conflict_base jsonb := '{}'::jsonb;
  v_conflict_local jsonb := '{}'::jsonb;
  v_conflict_remote jsonb := '{}'::jsonb;
  v_feed_payload jsonb := '{}'::jsonb;
  v_feed_kind text;
  v_feed_tombstone boolean := false;
  v_artifact_id uuid;
begin
  -- Payload byte bound before any mutation.
  if octet_length(v_payload::text) > (v_limits->>'max_operation_payload_bytes')::int then
    raise exception using errcode = '22023',
      message = 'operation payload exceeds limit';
  end if;

  -- Entity type must be allowlisted (mirrors client manifest).
  perform 1 from forge.replicated_entity_types where entity_type = v_entity_type;
  if not found then
    raise exception using errcode = '22023',
      message = format('entity type %s is not replicated', v_entity_type);
  end if;

  -- Allocate one gap-free server_seq for this operation. The allocator row is
  -- locked FOR UPDATE; a rejected group rolls the increment back.
  update forge.owner_sequences
    set next_server_seq = next_server_seq + 1
    where remote_profile_id = p_remote_profile_id
    returning next_server_seq - 1 into v_seq;
  if v_seq is null then
    raise exception using errcode = 'P0001', message = 'sequence allocator missing';
  end if;

  select true, e.tombstone, e.server_version
    into v_exists, v_tombstone, v_server_version
    from forge.entities e
    where e.remote_profile_id = p_remote_profile_id and e.entity_id = v_entity_id;
  v_exists := coalesce(v_exists, false);

  if v_kind = 'delete' then
    if not v_exists then
      raise exception using errcode = '23503',
        message = 'delete references unknown entity';
    end if;
    update forge.entities
      set tombstone = true,
          server_version = server_version + 1,
          snapshot_epoch = p_epoch,
          last_server_seq = v_seq,
          updated_at = statement_timestamp()
      where remote_profile_id = p_remote_profile_id and entity_id = v_entity_id
      returning server_version into v_server_version;
    v_feed_kind := 'delete';
    v_feed_tombstone := true;
    v_feed_payload := '{}'::jsonb;

  elsif v_kind = 'insert' and not v_exists then
    insert into forge.entities(
      remote_profile_id, entity_id, entity_type, server_version, tombstone,
      parent_entity_id, payload, snapshot_epoch, last_server_seq)
    values (
      p_remote_profile_id, v_entity_id, v_entity_type, 1, false,
      v_parent, v_payload, p_epoch, v_seq);
    for v_field, v_new_value in select key, value from jsonb_each(v_payload) loop
      insert into forge.entity_field_versions(
        remote_profile_id, entity_id, field, version, last_operation_id)
      values (p_remote_profile_id, v_entity_id, v_field, 1, v_operation_id);
    end loop;
    v_feed_kind := 'insert';
    v_feed_payload := v_payload;
    v_server_version := 1;

  else
    -- patch, or an insert whose entity already exists (treated as an upsert
    -- merge). Determine the set of fields to reconcile.
    if v_kind = 'patch' then
      if not v_exists then
        raise exception using errcode = '23503',
          message = 'patch references unknown entity';
      end if;
    end if;

    -- Reconcile each changed field with per-field version arithmetic.
    for v_field in
      select value::text from jsonb_array_elements_text(
        case when jsonb_array_length(v_changed) > 0
             then v_changed
             else (select coalesce(jsonb_agg(key), '[]'::jsonb) from jsonb_each(v_payload))
        end)
    loop
      v_new_value := v_payload -> v_field;
      select fv.version into v_cur_ver
        from forge.entity_field_versions fv
        where fv.remote_profile_id = p_remote_profile_id
          and fv.entity_id = v_entity_id and fv.field = v_field;
      v_cur_ver := coalesce(v_cur_ver, 0);
      v_base_ver := coalesce((v_base_fv->>v_field)::bigint, 0);

      if v_cur_ver > v_base_ver then
        -- Same-field contention: later server acceptance (this push) wins; the
        -- prior server value is preserved as the losing value (R-SYNC-004).
        select e.payload -> v_field into v_prior_value
          from forge.entities e
          where e.remote_profile_id = p_remote_profile_id
            and e.entity_id = v_entity_id;
        v_conflict_fields := v_conflict_fields || to_jsonb(v_field);
        v_conflict_base := v_conflict_base || jsonb_build_object(v_field, null);
        v_conflict_local := v_conflict_local || jsonb_build_object(v_field, v_new_value);
        v_conflict_remote := v_conflict_remote || jsonb_build_object(v_field, v_prior_value);
      end if;

      -- Apply the incoming value and bump the field version regardless (clean
      -- apply, disjoint merge, or conflict winner all advance the field).
      update forge.entities
        set payload = jsonb_set(payload, array[v_field], coalesce(v_new_value, 'null'::jsonb), true),
            snapshot_epoch = p_epoch,
            last_server_seq = v_seq,
            updated_at = statement_timestamp()
        where remote_profile_id = p_remote_profile_id and entity_id = v_entity_id;

      insert into forge.entity_field_versions(
        remote_profile_id, entity_id, field, version, last_operation_id)
      values (p_remote_profile_id, v_entity_id, v_field, v_cur_ver + 1, v_operation_id)
      on conflict (remote_profile_id, entity_id, field) do update
        set version = excluded.version, last_operation_id = excluded.last_operation_id;
    end loop;

    update forge.entities
      set server_version = server_version + 1,
          tombstone = false,
          snapshot_epoch = p_epoch,
          last_server_seq = v_seq,
          updated_at = statement_timestamp()
      where remote_profile_id = p_remote_profile_id and entity_id = v_entity_id
      returning server_version into v_server_version;

    v_feed_kind := case when v_kind = 'insert' then 'insert' else 'patch' end;
    v_feed_payload := v_payload;

    -- Persist a durable conflict artifact when a same-field contention was
    -- detected. It is pullable and durable until resolved plus retention.
    if jsonb_array_length(v_conflict_fields) > 0 then
      v_artifact_id := gen_random_uuid();
      insert into forge.sync_conflicts(
        remote_profile_id, artifact_id, entity_type, entity_id, fields,
        base_value, local_value, remote_value, policy, status,
        created_server_seq, snapshot_epoch)
      values (
        p_remote_profile_id, v_artifact_id, v_entity_type, v_entity_id,
        v_conflict_fields, v_conflict_base, v_conflict_local, v_conflict_remote,
        'later_server_acceptance', 'open', v_seq, p_epoch);
    end if;
  end if;

  -- Append the ordered change-feed row for this accepted operation.
  insert into forge.change_feed(
    remote_profile_id, server_seq, snapshot_epoch, entity_type, entity_id,
    kind, server_version, tombstone, parent_entity_id, payload, field_versions,
    group_id)
  values (
    p_remote_profile_id, v_seq, p_epoch, v_entity_type, v_entity_id,
    v_feed_kind, v_server_version, v_feed_tombstone, v_parent, v_feed_payload,
    forge._field_versions_json(p_remote_profile_id, v_entity_id), p_group_id);

  -- Record per-operation dedupe (same id/different hash rejected by caller).
  insert into forge.operation_receipts(
    remote_profile_id, operation_id, group_id, request_hash)
  values (p_remote_profile_id, v_operation_id, p_group_id,
    encode(sha256(convert_to(p_op::text, 'UTF8')), 'hex'));

  return jsonb_build_object('server_seq', v_seq, 'conflict_artifact_id', v_artifact_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Group-atomic push. Rejects a stale epoch before any mutation; validates
-- request/group limits; deduplicates by group id; and applies each group in an
-- isolated subtransaction so one group is fully accepted or fully rejected
-- without affecting the others (R-SYNC-003).
-- ---------------------------------------------------------------------------
create or replace function forge.push(
  p_remote_profile_id uuid,
  p_device_id uuid,
  p_snapshot_epoch bigint,
  p_groups jsonb
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, forge
as $$
declare
  v_limits jsonb := forge.protocol_limits();
  v_server_epoch bigint;
  v_results jsonb := '[]'::jsonb;
  v_group jsonb;
  v_group_id uuid;
  v_group_hash text;
  v_ops jsonb;
  v_op jsonb;
  v_op_count int;
  v_total_ops int := 0;
  v_receipt forge.group_receipts%rowtype;
  v_seen uuid[];
  v_parent uuid;
  v_seq_start bigint;
  v_seq_end bigint;
  v_op_result jsonb;
  v_idx int;
  v_op_hash text;
  v_existing_op forge.operation_receipts%rowtype;
  v_group_artifact uuid;
  v_group_result jsonb;
begin
  perform forge._require_owner(p_remote_profile_id);

  if jsonb_typeof(p_groups) <> 'array' then
    raise exception using errcode = '22023', message = 'groups must be an array';
  end if;
  if octet_length(p_groups::text) > (v_limits->>'max_push_request_bytes')::int then
    raise exception using errcode = '22023', message = 'push request exceeds byte limit';
  end if;
  if jsonb_array_length(p_groups) > (v_limits->>'max_groups_per_push')::int then
    raise exception using errcode = '22023', message = 'too many groups in push';
  end if;

  select snapshot_epoch into v_server_epoch
    from forge.remote_profiles where id = p_remote_profile_id;

  -- Stale-epoch rejection BEFORE any mutation: every group is reported
  -- stale_epoch and nothing is written (data-model.md §6).
  if p_snapshot_epoch < v_server_epoch then
    for v_group in select * from jsonb_array_elements(p_groups) loop
      v_results := v_results || jsonb_build_object(
        'group_id', v_group->>'group_id', 'outcome', 'stale_epoch');
    end loop;
    return jsonb_build_object(
      'protocol_version', 2, 'server_epoch', v_server_epoch, 'results', v_results);
  end if;
  if p_snapshot_epoch > v_server_epoch then
    raise exception using errcode = '22023',
      message = 'client epoch ahead of server';
  end if;

  -- Ensure the per-owner allocator exists.
  insert into forge.owner_sequences(remote_profile_id)
    values (p_remote_profile_id)
    on conflict (remote_profile_id) do nothing;

  -- Pre-count total operations across the batch.
  for v_group in select * from jsonb_array_elements(p_groups) loop
    v_total_ops := v_total_ops + jsonb_array_length(coalesce(v_group->'operations', '[]'::jsonb));
  end loop;
  if v_total_ops > (v_limits->>'max_operations_per_push')::int then
    raise exception using errcode = '22023', message = 'too many operations in push';
  end if;

  -- Process each group in its own subtransaction.
  for v_group in select * from jsonb_array_elements(p_groups) loop
    v_group_id := (v_group->>'group_id')::uuid;
    v_group_hash := encode(sha256(convert_to(v_group::text, 'UTF8')), 'hex');
    v_ops := coalesce(v_group->'operations', '[]'::jsonb);

    -- Idempotent replay: a known group id returns its stored result.
    select * into v_receipt from forge.group_receipts
      where remote_profile_id = p_remote_profile_id and group_id = v_group_id;
    if found then
      if v_receipt.request_hash <> v_group_hash then
        v_results := v_results || jsonb_build_object(
          'group_id', v_group_id::text, 'outcome', 'rejected',
          'rejection_reason', 'group id reused with a different request');
      else
        v_results := v_results || v_receipt.result;
      end if;
      continue;
    end if;

    begin
      v_op_count := jsonb_array_length(v_ops);
      if v_op_count = 0 then
        raise exception using errcode = '22023', message = 'empty group';
      end if;
      if v_op_count > (v_limits->>'max_operations_per_group')::int then
        raise exception using errcode = '22023', message = 'too many operations in group';
      end if;

      v_seen := array[]::uuid[];
      v_seq_start := null;
      v_seq_end := null;
      v_group_artifact := null;

      for v_idx in 0 .. v_op_count - 1 loop
        v_op := v_ops->v_idx;

        -- Contiguous 0-based indices.
        if (v_op->>'index')::int <> v_idx then
          raise exception using errcode = '22023',
            message = 'operation indices must be contiguous 0..n-1';
        end if;

        -- Parent-before-child / deferred-reference topology: a parent must
        -- already exist on the server or appear earlier in this same group.
        v_parent := nullif(v_op->>'parent_entity_id', '')::uuid;
        if v_parent is not null and v_parent <> (v_op->>'entity_id')::uuid then
          if not (v_parent = any(v_seen)) and not exists (
            select 1 from forge.entities e
            where e.remote_profile_id = p_remote_profile_id and e.entity_id = v_parent
          ) then
            raise exception using errcode = '23503',
              message = 'unresolved parent reference within group';
          end if;
        end if;

        -- Cross-group operation dedupe: same id/different hash is rejected.
        v_op_hash := encode(sha256(convert_to(v_op::text, 'UTF8')), 'hex');
        select * into v_existing_op from forge.operation_receipts
          where remote_profile_id = p_remote_profile_id
            and operation_id = (v_op->>'operation_id')::uuid;
        if found and v_existing_op.request_hash <> v_op_hash then
          raise exception using errcode = '22000',
            message = 'operation id reused with a different request';
        end if;

        v_op_result := forge._apply_operation(
          p_remote_profile_id, p_snapshot_epoch, v_group_id, v_op);
        v_seq_start := coalesce(v_seq_start, (v_op_result->>'server_seq')::bigint);
        v_seq_end := (v_op_result->>'server_seq')::bigint;
        if v_op_result->>'conflict_artifact_id' is not null then
          v_group_artifact := (v_op_result->>'conflict_artifact_id')::uuid;
        end if;
        v_seen := v_seen || (v_op->>'entity_id')::uuid;
      end loop;

      -- A group that produced a durable conflict artifact is still accepted and
      -- acknowledgeable, but reports outcome 'conflict' with the artifact id so
      -- the client links its outbox/journal to the durable artifact (R-SYNC-004).
      if v_group_artifact is not null then
        v_group_result := jsonb_build_object(
          'group_id', v_group_id::text, 'outcome', 'conflict',
          'conflict_artifact_id', v_group_artifact::text);
      else
        v_group_result := jsonb_build_object(
          'group_id', v_group_id::text, 'outcome', 'accepted');
      end if;

      insert into forge.group_receipts(
        remote_profile_id, group_id, request_hash, result,
        server_seq_start, server_seq_end)
      values (
        p_remote_profile_id, v_group_id, v_group_hash, v_group_result,
        v_seq_start, v_seq_end);

      v_results := v_results || v_group_result;
    exception when others then
      -- Group rejected: its subtransaction (including any server_seq the
      -- allocator advanced) rolls back, keeping accepted ordering gap-free.
      v_results := v_results || jsonb_build_object(
        'group_id', v_group_id::text, 'outcome', 'rejected',
        'rejection_reason', sqlerrm);
    end;
  end loop;

  return jsonb_build_object(
    'protocol_version', 2, 'server_epoch', v_server_epoch, 'results', v_results);
end;
$$;

comment on function forge.push(uuid, uuid, bigint, jsonb) is
  'Group-atomic idempotent push; stale epoch rejected before mutation (R-SYNC-003).';

-- ---------------------------------------------------------------------------
-- Ordered pull. Returns one contiguous page of changes by server_seq within
-- the owner's epoch, plus open durable conflict artifacts in range, plus the
-- next cursor and has_more (R-SYNC-003). An epoch mismatch signals bootstrap.
-- ---------------------------------------------------------------------------
create or replace function forge.pull(
  p_remote_profile_id uuid,
  p_snapshot_epoch bigint,
  p_after_server_seq bigint,
  p_limit integer
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, forge
as $$
declare
  v_limits jsonb := forge.protocol_limits();
  v_server_epoch bigint;
  v_limit int;
  v_after bigint := greatest(coalesce(p_after_server_seq, 0), 0);
  v_to_seq bigint;
  v_changes jsonb;
  v_conflicts jsonb;
  v_has_more boolean;
begin
  perform forge._require_owner(p_remote_profile_id);

  select snapshot_epoch into v_server_epoch
    from forge.remote_profiles where id = p_remote_profile_id;

  -- Epoch mismatch: the client must pull/bootstrap onto the current epoch
  -- before applying anything (data-model.md §6).
  if p_snapshot_epoch <> v_server_epoch then
    return jsonb_build_object(
      'protocol_version', 2,
      'remote_profile_id', p_remote_profile_id,
      'server_epoch', v_server_epoch,
      'epoch_mismatch', true);
  end if;

  v_limit := least(
    greatest(coalesce(p_limit, (v_limits->>'max_changes_per_pull_page')::int), 1),
    (v_limits->>'max_changes_per_pull_page')::int);

  -- Contiguous page ordered by server_seq.
  with page as (
    select *
      from forge.change_feed
      where remote_profile_id = p_remote_profile_id
        and snapshot_epoch = v_server_epoch
        and server_seq > v_after
      order by server_seq
      limit v_limit
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'change_id', server_seq::text,
      'entity_type', entity_type,
      'entity_id', entity_id,
      'kind', kind,
      'server_seq', server_seq,
      'server_version', server_version,
      'tombstone', tombstone,
      'parent_entity_id', parent_entity_id,
      'payload', payload,
      'field_versions', field_versions
    ) order by server_seq), '[]'::jsonb),
    max(server_seq)
    into v_changes, v_to_seq
    from page;

  v_to_seq := coalesce(v_to_seq, v_after);

  v_has_more := exists (
    select 1 from forge.change_feed
    where remote_profile_id = p_remote_profile_id
      and snapshot_epoch = v_server_epoch
      and server_seq > v_to_seq);

  -- Open, durable conflict artifacts created within this page's range are
  -- returned as ordinary pullable records (task 9.3 consumes them).
  select coalesce(jsonb_agg(jsonb_build_object(
    'artifact_id', artifact_id,
    'entity_type', entity_type,
    'entity_id', entity_id,
    'fields', fields,
    'base_value', base_value,
    'local_value', local_value,
    'remote_value', remote_value,
    'policy', policy,
    'status', status,
    'created_server_seq', created_server_seq
  ) order by created_server_seq), '[]'::jsonb)
  into v_conflicts
  from forge.sync_conflicts
  where remote_profile_id = p_remote_profile_id
    and snapshot_epoch = v_server_epoch
    and status = 'open'
    and created_server_seq > v_after
    and created_server_seq <= v_to_seq;

  return jsonb_build_object(
    'protocol_version', 2,
    'remote_profile_id', p_remote_profile_id,
    'snapshot_epoch', v_server_epoch,
    'from_server_seq', v_after,
    'to_server_seq', v_to_seq,
    'changes', v_changes,
    'conflicts', v_conflicts,
    'has_more', v_has_more,
    'next_cursor', jsonb_build_object(
      'epoch', v_server_epoch, 'server_seq', v_to_seq));
end;
$$;

comment on function forge.pull(uuid, bigint, bigint, integer) is
  'Ordered contiguous pull page by server_seq plus durable open conflicts (R-SYNC-003).';

-- ---------------------------------------------------------------------------
-- Grants: RPC is the only write path. Deny to anon; grant execute to
-- authenticated. Internal helpers are execute-denied to clients.
-- ---------------------------------------------------------------------------
revoke all on function forge.protocol_limits() from public, anon;
revoke all on function forge._require_owner(uuid) from public, anon, authenticated;
revoke all on function forge._field_versions_json(uuid, uuid) from public, anon, authenticated;
revoke all on function forge._apply_operation(uuid, bigint, uuid, jsonb) from public, anon, authenticated;
revoke all on function forge.push(uuid, uuid, bigint, jsonb) from public, anon;
revoke all on function forge.pull(uuid, bigint, bigint, integer) from public, anon;

grant execute on function forge.protocol_limits() to authenticated;
grant execute on function forge.push(uuid, uuid, bigint, jsonb) to authenticated;
grant execute on function forge.pull(uuid, bigint, bigint, integer) to authenticated;

commit;
