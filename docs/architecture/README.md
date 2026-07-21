# Architecture contract

Forge is a feature-first Flutter modular monolith using pragmatic Clean Architecture. The normative design is `.kiro/specs/forge/design.md`; data ownership and protocols are in `.kiro/specs/forge/data-model.md`.

Dependencies point inward: presentation invokes application contracts, application coordinates domain policy and ports, and infrastructure implements ports. Cross-feature access targets exported application contracts or typed domain events, never another feature's DAO or infrastructure. Core domain code has no Flutter, persistence, network, or plugin dependencies.

`tool/architecture_rules.json` is the machine-readable baseline and `tool/architecture_fitness.py` enforces dependency directions and lifecycle ownership. ADRs in `docs/adr/` record binding choices. Changes to architecture, schema, wire, backup, metrics, identity, support scope, or security require the applicable versioned ADR and compatibility/recovery evidence.

The active application shell owns routing, restoration, composition, localization, design tokens, focus and keyboard behavior. Durable state will belong to the encrypted local database; provider and Flutter restoration state are disposable projections. External routes use opaque IDs and centralized URI validation.
