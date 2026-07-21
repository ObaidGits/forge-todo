# Contributing to Forge

Forge accepts focused changes that preserve its local-first, accessible, privacy-preserving architecture. The authoritative implementation contract is `.kiro/specs/forge/README.md`; historical specs are not implementation authority.

## Set up

Install Flutter 3.44.6 at framework revision `ee80f08bbf97172ec030b8751ceab557177a34a6`. Run `flutter pub get --enforce-lockfile`, then `bash tool/ci/pr.sh`. Do not commit local configuration, credentials, user data, signing material, or generated secrets.

## Change contract

Every change must name exact requirement and task IDs, include proportionate tests, and update user/developer documentation when behavior changes. Architecture, schema, security, platform permission, backup, and release changes require the applicable ADR or compatibility/recovery record. Domain code cannot import Flutter, persistence, network, or plugin types.

Use synthetic test data. Report security issues through the private process in `SECURITY.md`, not a public issue. Contributions are made under the repository license and should include DCO sign-off (`Signed-off-by`) in commits.

## Validation

The pull-request gate validates formatting, analysis, tests, coverage, traceability, architecture, repository artifacts, dependencies, licenses, and secrets. Platform CI starts from a clean checkout and independently runs build, full tests, keyboard, and semantics checks for Android, iOS, Windows, and Linux. A build does not establish a support claim; see `SUPPORT.md`.
