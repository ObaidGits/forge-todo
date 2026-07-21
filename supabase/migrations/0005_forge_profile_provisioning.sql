-- Forge protocol-v2 sync backend — client-facing remote-profile provisioning.
--
-- Task 9.10 (R-SYNC-001, NFR-SEC-002). Migrations 0001/0002 gave the server its
-- schema and the push/pull write path, but there was NO sanctioned way for an
-- authenticated *client* to bring its own remote profile into existence — the
-- `forge.remote_profiles` table has read-only RLS and no write policy, so a
-- direct insert by the `authenticated` role is denied (by design). The
-- conformance script provisions rows as the migration owner, which a real
-- client cannot do.
--
-- This adds ONE reviewed SECURITY DEFINER RPC, `forge.ensure_remote_profile`,
-- that lets the authenticated account create (or idempotently re-read) its own
-- single remote profile. It keeps the whole security model intact:
--
--   * the owner is derived from auth.uid(), never trusted from the client;
--   * a caller may only ever own the profile keyed to its own uid (the
--     `owner_user_id` unique constraint enforces one profile per account);
--   * asking for a profile id already owned by a DIFFERENT account is denied
--     with insufficient_privilege (42501);
--   * table-level writes stay denied — this RPC is the only creation path;
--   * anon has no execute grant.
--
-- The remote profile id adopts the creating device's local profile id
-- (R-SYNC-001 "the remote profile adopts the creating device's local profile
-- id"); entity ids are never rekeyed.
--
-- Apply as a migration owner, never as a client role.

begin;

create or replace function forge.ensure_remote_profile(
  p_remote_profile_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, forge
as $$
declare
  v_auth uuid := auth.uid();
  v_owner uuid;
  v_epoch bigint;
  v_id uuid;
begin
  if v_auth is null then
    raise exception using errcode = '42501', message = 'authentication required';
  end if;

  -- If this account already owns a profile, return it unchanged (idempotent).
  select id, owner_user_id, snapshot_epoch
    into v_id, v_owner, v_epoch
    from forge.remote_profiles
    where owner_user_id = v_auth;
  if found then
    return jsonb_build_object(
      'remote_profile_id', v_id,
      'owner_user_id', v_owner,
      'snapshot_epoch', v_epoch,
      'created', false);
  end if;

  -- The requested id must not already belong to a different account.
  select owner_user_id into v_owner
    from forge.remote_profiles where id = p_remote_profile_id;
  if found and v_owner <> v_auth then
    raise exception using errcode = '42501',
      message = 'remote profile id already owned by another account';
  end if;

  insert into forge.remote_profiles(id, owner_user_id)
    values (p_remote_profile_id, v_auth);
  insert into forge.owner_sequences(remote_profile_id)
    values (p_remote_profile_id)
    on conflict (remote_profile_id) do nothing;

  select snapshot_epoch into v_epoch
    from forge.remote_profiles where id = p_remote_profile_id;

  return jsonb_build_object(
    'remote_profile_id', p_remote_profile_id,
    'owner_user_id', v_auth,
    'snapshot_epoch', v_epoch,
    'created', true);
end;
$$;

comment on function forge.ensure_remote_profile(uuid) is
  'Client-facing idempotent creation/read of the caller''s own remote profile; '
  'owner derives from auth.uid() (R-SYNC-001, NFR-SEC-002).';

revoke all on function forge.ensure_remote_profile(uuid) from public, anon;
grant execute on function forge.ensure_remote_profile(uuid) to authenticated;

commit;
