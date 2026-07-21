# Widgets

Home-screen widget bridge foundation (R-WIDGET-002, R-WIDGET-003, R-WIDGET-004).

This feature provides the Dart-side contracts and default implementations that
let native home-screen widgets render and act without opening the encrypted
database. The native platform channels and the widgets themselves are built in
later tasks (11.2/11.4); this layer is exercised with deterministic fakes.

## Layers

- `domain/`
  - `widget_surface.dart` — the stable widget surfaces (Today Tasks, Habit
    Checklist, Quick Note, Study/Focus countdown, Roadmap Progress).
  - `widget_snapshot.dart` — the redacted, versioned, local-only snapshot model
    with a freshness stamp and a deterministic canonical codec that fails safe
    on a newer/malformed format.
  - `widget_intent.dart` — the authenticated widget-originated intent envelope
    and its verified internal form.
  - `widget_snapshot_repository.dart` — local-only snapshot persistence port.
  - `widget_platform_contract.dart` — the single source of truth for the
    string constants (method channel, deep-link scheme/params, storage keys)
    shared with the native Android/iOS widgets.
  - `widget_deep_link.dart` — pure parser/builder for the `forge://widget/...`
    deep links a native tap opens; parsing yields an untrusted intent that the
    verifier still re-checks.
- `application/`
  - `widget_bridge.dart` — the `WidgetBridge` port plus the host-channel,
    signer, and command-handler ports.
  - `widget_snapshot_builder.dart` — enforces redaction, freshness, versioning,
    and bounded deterministic content.
  - `widget_intent_verifier.dart` — spoof resistance: signature, profile
    binding, and freshness checks.
  - `forge_widget_bridge.dart` — publishes snapshots and executes verified,
    idempotent intents that return committed receipts.
- `infrastructure/`
  - `keyed_hash_widget_intent_signer.dart` — the keyed-hash signer foundation.
  - `in_memory_widget_snapshot_store.dart` — local-only snapshot store.
  - `in_memory_widget_host_channel.dart` — deterministic host channel that
    round-trips through the canonical codec.
  - `platform_widget_host_channel.dart` — the production method-channel host
    that publishes canonical snapshots to the native shared container
    (Android `SharedPreferences`, iOS App Group `UserDefaults`).

## Native widgets (task 11.2)

The native home-screen widgets consume this bridge:

- Android: `android/app/src/main/kotlin/app/forge/forge/widgets/` (app widget
  providers, shared-storage reader, method-channel host) with layouts/sizes in
  `android/app/src/main/res/`.
- iOS: `ios/ForgeWidgets/` (WidgetKit extension) plus the Runner host in
  `ios/Runner/AppDelegate.swift`.

Real on-device rendering/placement is verified in task 11.4 and the manual
follow-ups recorded in those native READMEs.

## Invariants

- **Local-only:** snapshots never enter the outbox or sync.
- **Redaction:** under app-lock/privacy a snapshot carries no content or counts.
- **Freshness:** snapshots are timestamped so widgets can show a stale state.
- **Spoof resistance:** intents are authenticated and profile-bound.
- **Idempotency:** an intent maps to a deterministic durable command id, so a
  double-tap returns the same committed receipt with no duplicate effect.
