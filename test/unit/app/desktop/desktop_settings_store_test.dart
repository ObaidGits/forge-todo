import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/desktop/desktop_settings_store.dart';

/// Unit tests for the local-only desktop settings store (R-SYNC-002 local-only
/// class; ux-design §9). These values never sync.
void main() {
  group('InMemoryDesktopSettingsStore', () {
    test('given_seed_when_read_then_returns_value', () async {
      final InMemoryDesktopSettingsStore store = InMemoryDesktopSettingsStore(
        <String, String>{'k': 'v'},
      );
      expect(await store.read('k'), 'v');
      expect(await store.read('missing'), isNull);
    });

    test('given_write_null_when_read_then_removed', () async {
      final InMemoryDesktopSettingsStore store = InMemoryDesktopSettingsStore();
      await store.write('k', 'v');
      await store.write('k', null);
      expect(await store.read('k'), isNull);
    });
  });

  group('FileDesktopSettingsStore', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('forge_desktop_settings');
    });

    tearDown(() async {
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    });

    test('given_written_value_when_reopened_then_persists', () async {
      final File file = File('${dir.path}/settings.json');
      final FileDesktopSettingsStore store = FileDesktopSettingsStore(file);
      await store.write('window', '{"width":1}');

      final FileDesktopSettingsStore reopened = FileDesktopSettingsStore(file);
      expect(await reopened.read('window'), '{"width":1}');
    });

    test('given_missing_file_when_read_then_null', () async {
      final FileDesktopSettingsStore store = FileDesktopSettingsStore(
        File('${dir.path}/absent.json'),
      );
      expect(await store.read('anything'), isNull);
    });

    test('given_malformed_file_when_read_then_null_not_throw', () async {
      final File file = File('${dir.path}/settings.json');
      await file.writeAsString('{ not valid json');
      final FileDesktopSettingsStore store = FileDesktopSettingsStore(file);
      expect(await store.read('window'), isNull);
    });

    test('given_write_null_when_read_then_removed', () async {
      final File file = File('${dir.path}/settings.json');
      final FileDesktopSettingsStore store = FileDesktopSettingsStore(file);
      await store.write('k', 'v');
      await store.write('k', null);
      final FileDesktopSettingsStore reopened = FileDesktopSettingsStore(file);
      expect(await reopened.read('k'), isNull);
    });
  });
}
