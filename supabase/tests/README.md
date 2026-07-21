# Forge sync backend tests

These exercise the protocol-v2 server foundation (task 9.2) against a **live**
PostgreSQL/Supabase instance with `supabase/migrations/0001`–`0003` applied.

## In-repo vs live

- **In-repo (no database):** `tool/sync_server_lint.py` statically validates the
  migrations — RLS enabled and forced on every table, every table has an
  owner-scoped `select` policy referencing `auth.uid()` with no client write
  policy, `anon` is granted nothing, no client write grants, RPC functions are
  `security definer` with a pinned `search_path`, the entity allowlist matches
  the client manifest (`kReplicatedV1Entities`), the wire vocabulary and limits
  match the Dart contract, and no `forge-*` Storage bucket is created. Run by
  `python3 -m unittest tool/tests/test_sync_server_lint.py`.
- **Live (CI/manual):** two psql conformance scripts, both requiring a running
  database and therefore not part of the database-free repo gates:
  - `0001_protocol_conformance.sql` (task 9.2 server foundation) exercises
    group-atomic accept/reject, idempotent replay, ordered pull, direct-write
    denial, cross-owner RLS/RPC denial, stale-epoch rejection, and the
    object-Storage prohibition.
  - `0002_rls_surface.sql` (task 9.9) is the **complete owner-isolation
    surface**: negative-first assertions for every table and both RPCs —
    anonymous denial on every table read and RPC, cross-owner read invisibility
    on every owner-scoped table, cross-owner and forged/missing-JWT RPC denial,
    direct `insert`/`delete` denial on every table, operation-replay hash
    mismatch rejection, oversized-group rejection, the read-only reference
    allowlist, account-deletion cascade, and the object-Storage prohibition.

Client/server protocol compatibility is delivered in **task 9.10**: the
database-free agreement (protocol version, replicated entity set, wire
vocabulary, limits, RLS posture) plus the client TLS/non-E2EE disclosure and the
replaceable hosted/self-host backend configuration are cross-checked by
`tool/sync_server_lint.py --report`, which emits
`docs/evidence/sync-protocol-conformance.json`. Operator restore/self-host
verification reuses this directory's live scripts together with the
`tool/probes/supabase_conformance` harness — see
`docs/evidence/SYNC-PROTOCOL-CONFORMANCE.md`. Live hosted/self-hosted execution
remains operator-run.

## Running the live suite

Apply migrations, then run the conformance script. On Supabase the `auth.uid()`
function is provided. On a bare PostgreSQL CI job, define the shim first:

```sql
create schema if not exists auth;
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
create role anon nologin;
create role authenticated nologin;
```

```sh
psql "$DATABASE_URL" -f supabase/migrations/0001_forge_sync_schema.sql
psql "$DATABASE_URL" -f supabase/migrations/0002_forge_sync_rpc.sql
psql "$DATABASE_URL" -f supabase/migrations/0003_forge_no_object_storage.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/0001_protocol_conformance.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/0002_rls_surface.sql
```

Both scripts have been validated against an ephemeral `postgres:16-alpine`
container with the `auth.uid()` shim above; each scenario prints its `*_OK`
marker and the scripts finish with `SQL_CONFORMANCE_OK` / `RLS_SURFACE_CONFORMANCE_OK`.

Every scenario prints an `*_OK` marker; any failure raises and aborts under
`ON_ERROR_STOP`.
