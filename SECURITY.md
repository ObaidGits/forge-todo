# Security policy

## Supported lines

Forge is pre-release. No app or server line is currently designated stable or security-supported. Nightly and preview artifacts are evaluation-only; this file must be updated with exact versions and EOL dates before a stable release.

## Reporting

Do not open public issues for suspected vulnerabilities or include databases, backups, credentials, or personal data. Contact the maintainers through the repository host's private security-advisory channel. If that channel is unavailable, request a private contact path without disclosing exploit details.

Maintainers target acknowledgement within three business days and critical triage within 24 hours. Disclosure is coordinated after affected users have a practical mitigation. Never send a Forge database or backup unless a separately authenticated, consented support process has been established.

## Security baseline

The binding threat model is `.kiro/specs/forge/delivery.md`; the repository summary is `docs/security/threat-model.md`. CI gates dependency/license review, source and history secret scanning, architecture rules, repository contracts, and tests. Forge ships no telemetry by default. Existing encrypted data must never trigger replacement-key creation.

Unsigned or unverifiable artifacts are preview/nightly, never stable. Stable support additionally requires verified identity/signature, provenance, SBOM, notices, clean-install/upgrade evidence, recovery evidence, and an exact capability record.
