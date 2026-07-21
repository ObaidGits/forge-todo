# Supabase cloud setup

Forge is local-first and works fully offline. Optional cloud sync (and
Sign in with Google) is enabled only when a build is configured with a Supabase
backend. This runbook sets up that backend and wires it into a build.

For local dev against the CLI stack (`supabase start` / `db reset`), see the
"Local Supabase dev workflow" section in [DEVELOPMENT.md](../DEVELOPMENT.md).

## 1. Create the project and collect credentials

1. Create a project at [supabase.com](https://supabase.com) (or use an existing
   one).
2. From **Project Settings → General**, note the **project ref** (the
   `<ref>` in `https://<ref>.supabase.co`).
3. From **Project Settings → API**, collect:
   - **Project URL** — `https://<ref>.supabase.co` → `FORGE_SUPABASE_URL`
   - **anon public key** → `FORGE_SUPABASE_ANON_KEY`

   Only the **anon** (public) key is used by the app. Never ship or commit the
   `service_role` key.

## 2. Push the database schema

The sync schema, RLS policies, and RPCs live in `supabase/migrations/`. Push
them to your project with the Supabase CLI:

```sh
supabase login
supabase link --project-ref <ref>
supabase db push
```

`db push` applies the migrations that create the `forge` schema and its
SECURITY DEFINER RPCs (`forge.push` / `forge.pull` / `forge.ensure_remote_profile`),
which are the only sanctioned write path.

## 3. Expose the `forge` schema in the Data API

The Dart transport selects the sync schema with a `Content-Profile` /
`Accept-Profile: forge` header, so PostgREST must expose it:

- **Dashboard → Project Settings → API → Exposed schemas**: add **`forge`**
  (alongside `public` and `graphql_public`).

This changes nothing about the security model: RLS stays forced on every table,
table-level writes stay denied, the RPCs still derive the owner from
`auth.uid()`, and `anon` has no execute grant. (Locally this is already set in
`supabase/config.toml` under `[api] schemas`.)

## 4. Authentication

### Email / password (zero redirect config)

Email + password sign-in works with no redirect configuration. Enable it under
**Authentication → Sign In / Providers → Email**. Nothing else is required for
email/password to function.

### Google (requires the app redirect scheme wired)

Google sign-in needs OAuth configured on both Google and Supabase:

1. **Supabase → Authentication → Sign In / Providers → Google**: enable it and
   paste your Google OAuth **Client ID** and **Client secret**.
2. **Google Cloud Console** (APIs & Services → Credentials → your OAuth client):
   add the authorized redirect URI:

   ```
   https://<ref>.supabase.co/auth/v1/callback
   ```

3. **Supabase → Authentication → URL Configuration**: set the **Site URL** and
   add the app's redirect scheme to **Redirect URLs** so the OAuth round-trip
   returns to Forge. Unlike email/password, Google requires the app redirect
   scheme to be wired here.

## 5. Wire the keys into a build

Pass the URL and anon key as dart-defines (or via `--dart-define-from-file`):

```sh
flutter run -d linux \
  --dart-define=FORGE_SUPABASE_URL=https://<ref>.supabase.co \
  --dart-define=FORGE_SUPABASE_ANON_KEY=<public-anon-key>
```

When both are present, the in-app **Account & sync** screen can sign in and run
a manual sync. When either is absent, sync is off and the app stays local-first.
For CI-built release artifacts, these come from repository secrets — see
[RELEASE.md](RELEASE.md).
