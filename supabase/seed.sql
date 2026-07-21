-- Non-sensitive development seed for the Forge sync backend.
--
-- Creates two disposable remote profiles owned by fixed development UUIDs so a
-- local Supabase/PostgreSQL instance has data to exercise the RPCs. Contains no
-- real user content, credentials, or PII. Never applied to production.

begin;

insert into forge.remote_profiles(id, owner_user_id) values
  ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000d1'),
  ('00000000-0000-4000-8000-0000000000a2', '00000000-0000-4000-8000-0000000000d2')
on conflict (id) do nothing;

insert into forge.owner_sequences(remote_profile_id) values
  ('00000000-0000-4000-8000-0000000000a1'),
  ('00000000-0000-4000-8000-0000000000a2')
on conflict (remote_profile_id) do nothing;

commit;
