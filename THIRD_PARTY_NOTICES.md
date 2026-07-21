# Third-party notices

Machine-readable notice inputs live in `licenses/third_party.json`; the notice
shipped with application assets is `assets/licenses/NOTICE.txt`. Flutter's
runtime license registry remains available to the eventual application shell.

Dependencies must satisfy `licenses/policy.json`. Release automation must
regenerate artifact-specific notices and an SBOM from `pubspec.lock` and native
manifests; this source input is not a substitute for that release gate.
