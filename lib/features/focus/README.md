# Focus

Focus sessions and time tracking (R-FOCUS-001..006).

## Layering

- `domain/` — immutable aggregates and pure policies:
  - `focus_session.dart`, `focus_event.dart`, `focus_interval.dart` and their
    enums (`focus_mode`, `focus_session_status`, `focus_event_kind`,
    `focus_interval_kind`, `focus_link`).
  - `focus_time_policy.dart` — deterministic timer-truth reconciliation. While
    the boot id matches, elapsed time comes from the monotonic clock; after a
    reboot/discontinuity it falls back to bounded wall-clock reconciliation and
    becomes an explicit correction prompt when ambiguous (R-FOCUS-002).
  - `focus_preset.dart` — presets (including Deep Work) resolve to an ordinary
    mode + planned duration; a preset is not a separate data model (R-FOCUS-004).
  - `focus_policies.dart` — interval union for combined focus/study metrics so
    overlapping time is counted once (R-FOCUS-005).
  - `distraction_copy.dart` — capability-gated distraction messaging; Forge only
    claims blocking when an independently permissioned capability is active
    (R-FOCUS-006).
- `application/` — durable command surface (`focus_command_service.dart`,
  `focus_commands.dart`).
- `infrastructure/` — Drift tables (`focus_sessions`, `focus_intervals`,
  `focus_events`), mapper, transaction-scoped write repository, read model, the
  command-bus-backed service, canonical request, and repository factories.

## Invariants

- At most one open session per profile and at most one open interval per profile
  (partial unique indexes); no overlapping intervals (R-FOCUS-003).
- The lifecycle is append-only: start/pause/resume/end/cancel append immutable
  events and interval projections; corrections append audit events without
  rewriting history (R-FOCUS-003, R-FOCUS-005).
- Timer truth persists a wall anchor, a monotonic anchor, a boot id, and the
  accumulated completed duration (R-FOCUS-002).
