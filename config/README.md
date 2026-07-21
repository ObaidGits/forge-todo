# Typed build configuration

Copy an `*.example.json` file to a sibling name such as `release.json`; sibling
JSON files are ignored. Values are compiled through
`--dart-define-from-file` and parsed by `AppConfig`. Do not put credentials,
tokens, signing material, profile keys, service-role keys, or private URLs in
these files. Production authorization must never depend on a build define.
