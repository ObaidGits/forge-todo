# Data portability contract

**Validates: NFR-PORT-001**

Forge's canonical note content is UTF-8 Markdown. V1 human-readable export/import will use documented UTF-8 JSON, Markdown, and CSV with explicit schema versions, stable IDs, timestamps, units, unknown-field handling, collision-remap preview, and transactional validation. These are non-proprietary formats and must not require Forge infrastructure to inspect.

The encrypted FBC1 backup container is for authenticated point-in-time recovery, not the sole portability format. Its framing and cryptographic metadata are documented and versioned, but encrypted backup does not replace V1 human-readable export.

Wave 1 contains no production domain persistence or export UI. Therefore export is truthfully marked not yet available; CI preserves this contract so later work cannot claim proprietary-only export or advertise an unimplemented path.
