import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A narrow local-only key/value store for desktop-shell preferences such as
/// window geometry and close-to-tray behavior (ux-design §9).
///
/// These values are device-local operational settings, never user content and
/// never synced (R-SYNC-002 classifies generation/UI metadata as local-only).
/// The store is intentionally isolated from the durable encrypted database and
/// from any feature settings so the desktop shell can persist and restore
/// window state before the encrypted generation is open, and so it composes
/// independently of concurrent settings work.
abstract interface class DesktopSettingsStore {
  /// Returns the raw JSON-encoded value for [key], or null when absent.
  Future<String?> read(String key);

  /// Persists [value] (JSON-encoded) under [key], durably where the platform
  /// allows. Writing null removes the key.
  Future<void> write(String key, String? value);
}

/// An in-memory store for tests and for platforms without a writable profile
/// directory. Values survive for the process lifetime only.
final class InMemoryDesktopSettingsStore implements DesktopSettingsStore {
  InMemoryDesktopSettingsStore([Map<String, String>? seed])
    : _values = <String, String>{...?seed};

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }
}

/// A JSON-file-backed store under the desktop app-support directory.
///
/// The file holds a flat string map. Writes are atomic (temp file + rename) so
/// an interrupted write never corrupts existing preferences (NFR-REL-002). All
/// I/O failures degrade to in-memory behavior rather than crashing the shell;
/// desktop preferences are best-effort and never block core work.
final class FileDesktopSettingsStore implements DesktopSettingsStore {
  FileDesktopSettingsStore(this._file);

  final File _file;
  Map<String, String>? _cache;

  Future<Map<String, String>> _load() async {
    if (_cache case final Map<String, String> cached) {
      return cached;
    }
    Map<String, String> loaded = <String, String>{};
    try {
      if (_file.existsSync()) {
        final Object? decoded = jsonDecode(await _file.readAsString());
        if (decoded is Map<String, dynamic>) {
          loaded = <String, String>{
            for (final MapEntry<String, dynamic> e in decoded.entries)
              if (e.value is String) e.key: e.value as String,
          };
        }
      }
    } on Object {
      // Unreadable or malformed preferences start empty; never fatal.
      loaded = <String, String>{};
    }
    return _cache = loaded;
  }

  @override
  Future<String?> read(String key) async => (await _load())[key];

  @override
  Future<void> write(String key, String? value) async {
    final Map<String, String> values = await _load();
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    try {
      await _file.parent.create(recursive: true);
      final File tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(jsonEncode(values), flush: true);
      await tmp.rename(_file.path);
    } on Object {
      // Persistence is best-effort; the in-memory cache still reflects intent.
    }
  }
}
