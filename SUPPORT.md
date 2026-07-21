# Support

Forge is currently pre-release. No generated artifact or target is Full support while its capability record is unverified, unsigned, or missing clean-install, upgrade, accessibility, recovery, and package-identity evidence.

The generated matrix is `docs/support/capability-matrix.md`; exact evidence still requiring an isolated target or physical device is `docs/support/external-evidence.md`. Machine-readable source evidence is `docs/evidence/scheduling-capability-matrix.v1.json`. Build success alone does not change support status.

MVP targets Android, Windows, and individually validated Linux distribution/desktop/package combinations. iOS is build/spike-only until the V1 support gate. Web and macOS are not supported targets. Untested OS versions, architectures, Linux combinations, Windows identities, or package types are unsupported rather than inferred from a nearby result.

Use public issues only for non-sensitive defects with synthetic reproduction data. Security concerns follow `SECURITY.md`. Recovery guidance is in `docs/user/recovery.md`; no support request should ask for a user database or backup without an explicit secure consent process.
