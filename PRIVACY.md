# Privacy

Forge is designed for local-first use. Core workflows require no account or network, and remote telemetry or crash reporting is not enabled by default. The current Wave 1 shell contains no production domain database or sync implementation.

User content is intended to remain in the encrypted local data store. Optional V1 sync, when implemented and enabled, will use TLS but is not end-to-end encrypted; the chosen server operator can read synced content. Local-only drafts, key material, attachment keys and paths, diagnostics, and private device settings are excluded from sync by contract.

Logs and diagnostics use allowlisted structured metadata and redact content, credentials, identifiers, paths, and URIs. A diagnostics export requires preview and consent and excludes domain content by default. Restoration state and external routes contain opaque IDs only, never note text, titles, tokens, file paths, or search terms.

Forge requests permissions only at point of use, explains degradation, and does not block unrelated local work after denial. Files use system pickers/scoped access; broad storage and accessibility-service blocking permissions are prohibited. Future privacy-affecting behavior must update this notice and its tests in the same change.
