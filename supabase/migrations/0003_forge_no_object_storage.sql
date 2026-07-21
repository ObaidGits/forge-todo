-- Forge protocol-v2 sync backend — explicit non-use of object Storage in V1,
-- and hint-only Realtime.
--
-- Task 9.2 (NFR-SEC-002, R-SYNC-002/§3 exclusion). V1 does NOT synchronize
-- attachments. Attachment metadata, files, and file journals are local-only
-- (data-model.md §3; tool/probes/supabase_conformance/config/
-- remote-attachment-policy.json). This migration ENFORCES that no Forge object
-- Storage bucket or object policy exists, so a mis-provisioned environment
-- fails closed rather than silently gaining a remote file surface.
--
-- Promoting remote attachment storage requires an approved Post-V1 scope-change
-- ADR. Until then, the only remote surfaces are the tables and RPCs in
-- 0001/0002.

begin;

-- Fail closed if any Forge-prefixed Storage bucket exists. The upstream Storage
-- service image may be present as part of the official stack, but Forge V1 must
-- own no bucket or object policy.
do $$
begin
  if to_regclass('storage.buckets') is not null then
    if exists (
      select 1 from storage.buckets
      where id like 'forge-%' or name like 'forge-%'
    ) then
      raise exception using errcode = '42501',
        message = 'V1 remote attachment storage is prohibited (no forge-* bucket allowed)';
    end if;
  end if;
end;
$$;

-- Realtime is ONLY a pull hint (data-model.md §6). The authoritative ordered
-- stream is forge.change_feed via the pull RPC; clients must still pull. If the
-- Realtime publication exists, register the change feed as a hint source. RLS
-- still restricts every row to its owner.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and to_regclass('forge.change_feed') is not null
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'forge' and tablename = 'change_feed'
     ) then
    alter publication supabase_realtime add table forge.change_feed;
  end if;
end;
$$;

comment on table forge.change_feed is
  'Authoritative ordered pull stream; Realtime membership is a non-authoritative hint only.';

commit;
