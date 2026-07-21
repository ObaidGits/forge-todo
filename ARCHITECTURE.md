# Architecture

A concise map of how Forge is built. For the persisted data model, see
[docs/architecture/data-dictionary.md](docs/architecture/data-dictionary.md);
architecture decision records live in [docs/adr/](docs/adr/).

## Shape

Forge is a **Flutter modular monolith**: one app, one process, one database
engine, composed from independent feature modules. It is **local-first** — the
device holds the source of truth and the app is fully functional offline. Cloud
sync is an optional, replaceable add-on.

## Source of truth: encrypted Drift store

- Persistence is **[Drift](https://drift.simonbinder.eu/)** over an **encrypted
  SQLite database using SQLite3 Multiple Ciphers (sqlite3mc)**. The native asset
  is selected in `pubspec.yaml` (`hooks.user_defines.sqlite3: sqlite3mc`) and the
  store opens with a `PRAGMA key` (ADR-0001).
- The 32-byte database key is custodied by a **device key vault** — the OS secret
  service (`libsecret` / Keychain / DPAPI / Android Keystore) when reachable, with
  a local file-vault fallback. A key is provisioned only on a provably fresh
  install; existing ciphertext with no key fails closed into **Recovery Mode**
  rather than resetting data (R-SEC-001).
- A single **`DatabaseRuntime`** owns the opened store, and all mutations pass
  through one **writer lock / command bus** (`ForgeCommandBus`) over a shared
  unit of work, so writes are serialized and search projections update inside the
  same transaction as the change that triggered them.

## Feature-first layering

Each feature under `lib/features/<name>/` is organized into the same layers:

- **domain** — entities, value objects, and repository/port interfaces. Pure
  Dart, no framework or plugin imports.
- **application** — use cases and command/query services orchestrating domain
  logic (e.g. `TaskCommandService`, `PeriodInsightsService`).
- **infrastructure** — Drift DAOs, repository implementations, and the concrete
  adapters that fulfill domain ports (including plugin-backed adapters).
- **presentation** — Riverpod providers and Flutter UI.

Shared primitives live in `lib/core/` (clock, ids, security, theme), and
`lib/app/` holds bootstrap and composition. The **composition root**
(`lib/app/bootstrap.dart`) is the one place that assembles every feature's
repository factories into the shared unit of work and constructs the wired
services; `lib/main.dart` overrides Riverpod providers with those instances.

State management is **Riverpod**; routing is **go_router**.

## Plugins stay behind ports

Third-party plugins never leak past an infrastructure adapter that implements a
domain/application port, so the domain stays pure and testable:

- OS notifications (`flutter_local_notifications`) sit behind
  `NotificationTransport`; the reminder service and rolling-horizon reconciler
  are plugin-free.
- Optional Supabase sync (`http` + GoTrue) sits behind the sync transport/auth
  ports — no domain or other feature imports `package:http`.
- Desktop capabilities (window, tray, global hotkey, autostart) sit behind
  desktop ports under `lib/app/desktop/*`, guarded by platform.

## Optional cloud sync (replaceable adapter)

Sync is an **optional adapter**, not a dependency. It activates only when the
`FORGE_SUPABASE_URL` / `FORGE_SUPABASE_ANON_KEY` dart-defines are set; otherwise
the sync service is null and the app is purely local. The backend is a Supabase
Postgres project whose `forge` schema exposes SECURITY DEFINER RPCs
(`forge.push` / `forge.pull` / `forge.ensure_remote_profile`) as the only
sanctioned write path — RLS is forced, table-level writes are denied, and the
owner is derived from `auth.uid()`. Because it lives behind ports, the sync
backend could be replaced without touching feature domains.

## Desktop widget mode

On desktop (Linux/Windows), Forge can run as a frameless, always-on-top
**sticky widget** with a system-tray icon, a global summon/toggle hotkey
(default Ctrl+Alt+T), and autostart-on-login. This shell is composed only on
desktop platforms and is entirely inert on mobile. On mobile, home-screen
widgets, biometric app-lock, and share-intent capture are wired instead — each
guarded by platform.

## Platform support

- **Linux** and **Android** — actively developed and verified locally.
- **Windows** — built and validated via CI (the Inno Setup installer cannot be
  compiled on Linux).
- **iOS** — build-only until V1.
- **Web and macOS** — intentionally not scaffolded.
