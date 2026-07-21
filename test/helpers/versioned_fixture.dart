import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

Map<String, Object?> _freezeMap(Map<String, Object?> value) =>
    Map<String, Object?>.unmodifiable(
      value.map(
        (String key, Object? nestedValue) =>
            MapEntry<String, Object?>(key, _freezeJson(nestedValue)),
      ),
    );

Object? _freezeJson(Object? value) => switch (value) {
  final Map<String, Object?> map => _freezeMap(map),
  final List<Object?> list => List<Object?>.unmodifiable(list.map(_freezeJson)),
  _ => value,
};

final class VersionedFixture {
  VersionedFixture._({
    required this.fixtureId,
    required this.fixtureFormatVersion,
    required this.dataSchemaVersion,
    required this.releaseTag,
    required Map<String, Object?> payload,
  }) : payload = _freezeMap(payload);

  final String fixtureId;
  final int fixtureFormatVersion;
  final int dataSchemaVersion;
  final String releaseTag;
  final Map<String, Object?> payload;

  static VersionedFixture decode(List<int> bytes) {
    final Object? decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Fixture root must be an object.');
    }
    final Object? fixtureId = decoded['fixture_id'];
    final Object? fixtureVersion = decoded['fixture_format_version'];
    final Object? schemaVersion = decoded['data_schema_version'];
    final Object? releaseTag = decoded['release_tag'];
    final Object? payload = decoded['payload'];
    if (fixtureId is! String || !_fixtureId.hasMatch(fixtureId)) {
      throw const FormatException('Fixture ID is invalid.');
    }
    if (fixtureVersion is! int || fixtureVersion <= 0) {
      throw const FormatException('Fixture format version must be positive.');
    }
    if (schemaVersion is! int || schemaVersion <= 0) {
      throw const FormatException('Data schema version must be positive.');
    }
    if (releaseTag is! String ||
        !const <String>{'MVP', 'V1', 'Post-V1'}.contains(releaseTag)) {
      throw const FormatException('Fixture release tag is invalid.');
    }
    if (payload is! Map<String, Object?>) {
      throw const FormatException('Fixture payload must be an object.');
    }
    return VersionedFixture._(
      fixtureId: fixtureId,
      fixtureFormatVersion: fixtureVersion,
      dataSchemaVersion: schemaVersion,
      releaseTag: releaseTag,
      payload: payload,
    );
  }

  static final RegExp _fixtureId = RegExp(r'^[a-z][a-z0-9_]*_v[0-9]+$');
}

final class FixtureManifestEntry {
  const FixtureManifestEntry({required this.path, required this.sha256});

  final String path;
  final String sha256;
}

final class VersionedFixtureLoader {
  const VersionedFixtureLoader(this.root);

  final Directory root;

  Future<VersionedFixture> load(FixtureManifestEntry entry) async {
    if (entry.path.isEmpty ||
        entry.path.startsWith('/') ||
        entry.path.contains('..') ||
        entry.path.contains('\\')) {
      throw FormatException('Unsafe fixture path: ${entry.path}');
    }
    if (!_sha256Pattern.hasMatch(entry.sha256)) {
      throw const FormatException('Fixture SHA-256 is invalid.');
    }
    final File file = File('${root.path}/${entry.path}');
    final FileStat stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw StateError('Fixture is not a regular file: ${entry.path}');
    }
    final List<int> bytes = await file.readAsBytes();
    final String actual = sha256.convert(bytes).toString();
    if (actual != entry.sha256) {
      throw StateError('Fixture checksum mismatch for ${entry.path}: $actual.');
    }
    return VersionedFixture.decode(bytes);
  }

  static final RegExp _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');
}

final class FixtureManifest {
  FixtureManifest._({required this.version, required this.entries});

  final int version;
  final List<FixtureManifestEntry> entries;

  static FixtureManifest decode(List<int> bytes) {
    final Object? decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?> ||
        decoded['manifest_version'] is! int ||
        (decoded['manifest_version']! as int) <= 0 ||
        decoded['fixtures'] is! List<Object?>) {
      throw const FormatException('Fixture manifest is invalid.');
    }
    final List<FixtureManifestEntry> entries =
        (decoded['fixtures']! as List<Object?>)
            .map((Object? value) {
              if (value is! Map<String, Object?> ||
                  value['path'] is! String ||
                  value['sha256'] is! String) {
                throw const FormatException(
                  'Fixture manifest entry is invalid.',
                );
              }
              return FixtureManifestEntry(
                path: value['path']! as String,
                sha256: value['sha256']! as String,
              );
            })
            .toList(growable: false);
    if (entries.isEmpty) {
      throw const FormatException('Fixture manifest must not be empty.');
    }
    return FixtureManifest._(
      version: decoded['manifest_version']! as int,
      entries: List<FixtureManifestEntry>.unmodifiable(entries),
    );
  }
}
