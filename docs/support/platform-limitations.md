# Platform limitations

Current target records are unverified and cannot be labeled Full support. Android background work, exact alarms, notification actions, and OEM restrictions vary by device. iOS background execution is opportunistic and is build-only before V1. Windows notifications and secure storage depend on package identity. Linux behavior depends on the exact distribution, desktop, package, notification daemon, accessibility stack, and Secret Service availability.

CI proves source-contract validity, compilation, Flutter tests, keyboard behavior, and semantics assertions on target runners. It cannot prove physical notification delivery, background limits, biometrics, secure storage persistence, package install/upgrade identity, screen-reader experience, signing, or performance. Those requirements are enumerated without substitution in `external-evidence.md`.

Absent secure key storage may use only the validated passphrase-wrapped fallback with disclosed degradation. If neither is available, that exact target is unsupported; plaintext databases or keys are forbidden.
