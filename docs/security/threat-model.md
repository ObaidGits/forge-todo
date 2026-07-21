# Threat model summary

The normative threat model is `.kiro/specs/forge/delivery.md` section 8. This summary is a repository navigation artifact, not a waiver or replacement.

Forge protects against loss or theft of a locked device, backup tampering, cross-owner sync access, replay, supply-chain compromise, log leakage, unsafe files and links, spoofed intents, and partial migration/restore. Required controls include encrypted local storage, fail-closed key release, authenticated bounded backups, ownership checks, idempotent receipts, exact dependency pins, redaction, staged file handling, centralized URI policy, and verified generation switching.

Residual risks are explicit: a compromised OS can access runtime memory; weak user secrets remain weak; optional sync is TLS-protected but not E2EE; externally opened files leave Forge's trust boundary; native dependencies require continuous review; physical storage may not securely erase freed blocks.

CI release gates include threat-model presence, dependency and license scanning, secret scanning, architecture fitness, deterministic repository artifacts, and target tests. Later release waves add independent crypto, key lifecycle, Auth/RLS, attachment, signing, SBOM, provenance, and restore evidence. Failed security evidence removes or downgrades a capability claim; it never permits plaintext data or keys.
