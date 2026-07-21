<div align="center">

# 🔥 Forge

### *Build Better Every Day*

**A local-first, privacy-respecting personal productivity operating system — tasks, notes, habits, goals, learning, focus, and reflection in one calm, coherent app.**

[![Platforms](https://img.shields.io/badge/platforms-Android%20%7C%20Linux%20%7C%20Windows-2ea44f)](#-platform-support)
[![Flutter](https://img.shields.io/badge/Flutter-3.44.6-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Local-first](https://img.shields.io/badge/local--first-encrypted-8e44ad)](#-privacy--security)
[![Sync](https://img.shields.io/badge/sync-optional%20(Supabase)-3ECF8E?logo=supabase&logoColor=white)](#-cloud-sync-optional)

[Download](#-download--install) · [Features](#-features) · [Why Forge](#-why-forge) · [Setup](#-cloud-sync-optional) · [Developers](#-for-developers) · [Author](#-about-the-developer)

</div>

---

## ✨ Overview

**Forge** helps one person intentionally **plan, execute, learn, reflect, and improve** — without surrendering ownership of their data. It blends the most useful qualities of reminders, task managers, note tools, habit trackers, and personal dashboards into a single mental model:

> **Life Area → Outcome / Work → Activity → Reflection**

Everything is stored in an **encrypted, on-device database** and works **fully offline**. Cloud sync across your devices is **optional** — enable it only if you want it, sign in with Google, and your data stays yours (row-level isolated, TLS-protected).

No ads. No tracking. No subscription to use the core app. No telemetry by default.

---

## 💡 Why Forge

Most productivity apps make you choose between **convenience** and **ownership** — either your notes and tasks live on someone else's servers, or you get a clunky offline tool with no sync. They fragment your life across a dozen subscriptions, nudge you with manipulative streak-shaming, and lock your data in.

Forge was built on a different belief:

- **Your data is yours.** It lives encrypted on your device first. Sync is additive, never mandatory.
- **One coherent system beats ten disconnected apps.** Tasks, habits, notes, goals, learning, and focus share one model, so today's work connects to your long-term outcomes.
- **Progress should be honest.** No opaque "productivity scores," no addictive pressure — just clear, explainable numbers based on *your own* records.
- **Works forever, offline.** No account or network required for the core experience.

It's a personal productivity OS for people who want to build a better life **and** keep control of their information.

---

## 🎯 What It Solves

| Problem | How Forge helps |
|---|---|
| Data scattered across many apps | One app for tasks, notes, habits, goals, learning, focus & reflection |
| Privacy & lock-in worries | Local-first, **encrypted** storage; export & self-hostable optional sync |
| "What should I do *now*?" | A calm **Today** view that surfaces what matters without configuration |
| Losing long-term direction | **Goals + roadmaps** connect daily work to real outcomes |
| Guilt-driven habit apps | Neutral, non-shaming **habits** with transparent streak/consistency math |
| Fear of losing work | Encrypted **backup & restore** + a non-destructive Recovery Mode |
| No internet / travel | Everything works **offline**; sync reconciles when you're back |

---

## 🧩 Features

### 📋 Core productivity
- **Today dashboard** — overdue & due tasks, today's habits, active study, focus session, quick capture, and progress rings, all in one glanceable screen.
- **Tasks** — quick capture, priorities, subtasks, due/scheduled dates, tags, **recurrence** (RFC-5545 subset), saved filters, reversible completion, Trash + Undo.
- **Goals & Roadmaps** — outcomes with milestones and ordered roadmaps; transparent, explainable progress (no double-counting, no fake scores).
- **Learning** — track courses, books, playlists & articles; append-only **study sessions**; "resume where you left off."
- **Habits** — daily / weekly / monthly schedules; boolean, count, duration, quantity & abstinence targets; streaks & consistency with neutral, non-shaming copy.
- **Notes** — canonical **Markdown** with live preview, `[[wiki-links]]` + backlinks, pin/archive/tags, and encrypted crash-safe autosave drafts.
- **Planner** — daily / weekly / monthly reflection records (morning plan, daily plan, evening reflection) that reference — never clone — your tasks & goals.
- **Focus & time** — count-up or interval (Pomodoro / Deep Work) sessions with reliable wall + monotonic timing; links to tasks, goals, and study.
- **Fitness** — workout templates, sessions, sets & body-weight tracking (units preserved; non-medical).
- **Insights** — weekly/monthly, fully explainable metrics with numerator/denominator, trends, and accessible table alternatives.
- **Global search** — fast full-text search across everything (tasks, notes, goals, habits, learning, workouts).
- **Reminders** — local OS notifications with quiet hours, timezone-correct scheduling, and honest capability diagnostics.

### 🖥️ Desktop widget (Linux & Windows)
A **sticky Today + Notes widget**: frameless, draggable, **always-on-top** ("display over other apps"), opacity & lock controls, **system tray**, **autostart on login**, and a **global hotkey** — all controllable from Settings.

### 🔒 Trust & resilience
- **Encrypted local database** (SQLite Multiple Ciphers / sqlite3mc) — data is encrypted at rest.
- **OS-backed key storage** (libsecret / Keychain / DPAPI) with a safe fallback.
- **Encrypted backup & restore** (FBC1 format) and a non-destructive **Recovery Mode**.
- **Accessibility-first** — targets WCAG 2.2 AA: keyboard operable, screen-reader labels, reduced-motion, high-contrast & dark themes, text-scaling.

---

## ☁️ Cloud Sync (optional)

Forge is **local-first** — it works completely offline and stores everything encrypted on your device. If you want your tasks and notes on more than one device:

1. Open **Settings → Account & sync**.
2. **Sign in with Google** (or email + password).
3. Done — your data syncs securely.

Under the hood it uses an optional **Supabase** backend with **Row-Level Security**, so each account only ever sees its own data. Sync is **TLS-protected** (not end-to-end encrypted). Builds without a configured backend simply keep everything on-device.

> Self-hosting or running your own backend? See [`docs/SUPABASE_SETUP.md`](docs/SUPABASE_SETUP.md).

---

## 📥 Download & Install

Grab the latest build for your platform from the **[Releases](https://github.com/ObaidGits/forge-todo/releases)** page.

### 🤖 Android (APK)
1. Download `Forge-<version>.apk` to your phone.
2. Open it → Android asks to allow installs from this source → **Allow**, then install.
3. Launch Forge from your app drawer.

### 🪟 Windows (installer)
1. Download and run `Forge-<version>-windows-setup.exe`.
2. If SmartScreen warns about an unknown publisher → **More info → Run anyway**.
3. Installs per-user (no admin), adds the Visual C++ runtime if needed, and creates Start-menu / desktop shortcuts.

### 🐧 Linux (AppImage)
```sh
chmod +x Forge-*-x86_64.AppImage
./Forge-*-x86_64.AppImage
```
On Debian/Ubuntu, ensure the runtime libs are present:
```sh
sudo apt-get install libgtk-3-0 libsecret-1-0
```

> These builds are distributed directly via GitHub (no app store required). Because they aren't store-signed, your OS may show a one-time "unknown source/publisher" prompt — this is expected for open-source sideloaded apps.

---

## 🧭 Platform Support

| Platform | Status |
|---|---|
| 🐧 **Linux** (x64) | ✅ Supported & tested |
| 🤖 **Android** (API 24+) | ✅ Supported & tested |
| 🪟 **Windows** (x64) | 🧪 Built via CI — validated on release |
| 🍏 **iOS / macOS** | 🔜 Planned (not yet released) |
| 🌐 **Web** | ⛔ Not a target |

---

## 🔐 Privacy & Security

- **Local-first & encrypted** — your database is encrypted at rest; the device key is held in the OS secret store.
- **No telemetry by default** — Forge ships no analytics or tracking.
- **No content in logs** — structured logging is redaction-safe by design.
- **Your data is portable** — export/import and encrypted backups mean you're never locked in.
- **Optional sync is isolated** — Row-Level Security ensures one account can never read another's data.

See [`SECURITY.md`](SECURITY.md) and [`PRIVACY.md`](PRIVACY.md).

---

## 🛠️ Tech Stack

- **[Flutter](https://flutter.dev) 3.44.6 / Dart 3.12.2** — one codebase, native performance on mobile & desktop.
- **[Drift](https://drift.simonbinder.eu/) + SQLite Multiple Ciphers (sqlite3mc)** — encrypted, transactional local storage as the source of truth.
- **[Riverpod](https://riverpod.dev/)** — composition & state management.
- **[Supabase](https://supabase.com/)** (optional) — Postgres + Auth + RLS for cross-device sync.
- **pointycastle** — AES-256-GCM / Argon2id for draft & backup encryption.
- Pragmatic **Clean Architecture**, feature-first modules, transactional command bus, typed after-commit events.

---

## 👩‍💻 For Developers

- **[DEVELOPMENT.md](DEVELOPMENT.md)** — toolchain setup, running, and testing on each platform.
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — how Forge is structured.
- **[docs/RELEASE.md](docs/RELEASE.md)** — tagging & publishing GitHub Releases.
- **[docs/SUPABASE_SETUP.md](docs/SUPABASE_SETUP.md)** — configuring the optional cloud backend.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — contribution guidelines.

Quick start:
```sh
flutter pub get
flutter run -d linux          # or: flutter run -d <android-device>
flutter analyze
flutter test
```
Source is **MIT licensed** — see [`LICENSE`](LICENSE), [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md), and `assets/licenses/NOTICE.txt`.

---

## 🙋 About the Developer

**Forge is designed and built by Obaidullah Zeeshan** — a developer passionate about privacy-respecting, local-first software that puts people back in control of their data.

<div align="center">

[![Portfolio](https://img.shields.io/badge/Portfolio-obaidullah--zeeshan.dev-000000?logo=firefox&logoColor=white)](https://obaidullah-zeeshan.dev)
[![GitHub](https://img.shields.io/badge/GitHub-ObaidGits-181717?logo=github&logoColor=white)](https://github.com/ObaidGits)
[![LinkedIn](https://img.shields.io/badge/LinkedIn-obaidullah--zeeshan-0A66C2?logo=linkedin&logoColor=white)](https://linkedin.com/in/obaidullah-zeeshan)

</div>

- 🌐 Portfolio: **https://obaidullah-zeeshan.dev**
- 💻 GitHub: **https://github.com/ObaidGits**
- 💼 LinkedIn: **https://linkedin.com/in/obaidullah-zeeshan**

If Forge is useful to you, a ⭐ on the repo is genuinely appreciated — it helps others discover it.

---

## 📄 License

Released under the **MIT License**. See [`LICENSE`](LICENSE).

<div align="center">

**Forge — Build Better Every Day.** 🔥

</div>
