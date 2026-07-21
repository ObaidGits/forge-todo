import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/encrypted/sqlite3mc_encrypted_store.dart';
import 'package:forge/app/infrastructure/database/encrypted_store.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/security/key_vault.dart';

/// A fixed-bytes key lease for tests.
final class _RawKeyLease implements KeyLease {
  _RawKeyLease(this._bytes);

  final Uint8List _bytes;
  bool _disposed = false;

  @override
  bool get isDisposed => _disposed;

  @override
  Uint8List copyBytes() => Uint8List.fromList(_bytes);

  @override
  Future<void> dispose() async => _disposed = true;
}

Uint8List _key(int seed) => Uint8List.fromList(
  List<int>.generate(32, (int i) => (i * 7 + seed) & 0xff),
);

Future<int> _profileCount(Sqlite3mcEncryptedStore store) async {
  final rows = await store.database
      .customSelect('SELECT count(*) AS c FROM profiles')
      .get();
  return rows.single.read<int>('c');
}

Future<void> _insertProfile(Sqlite3mcEncryptedStore store, String id) async {
  await store.database.customStatement(
    'INSERT INTO profiles '
    '(id, display_name, locale, timezone_id, week_start, hour_format, '
    'is_active, created_at_utc, updated_at_utc) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    <Object?>[id, 'You', 'en', 'Etc/UTC', 1, 'h24', 1, 0, 0],
  );
}

void main() {
  group('Sqlite3mcEncryptedStore', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('forge-enc-store-');
    });

    tearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    test(
      'opens a fresh store, persists data, and reopens with the key',
      () async {
        final opener = Sqlite3mcEncryptedStoreOpener(
          repositoryFactories: <Type, RepositoryFactory>{},
        );
        final EncryptedStore fresh = await opener.open(
          EncryptedStoreRequest(
            generationDirectory: dir.path,
            schemaVersion: 14,
            keyLease: _RawKeyLease(_key(1)),
            expectFreshStore: true,
          ),
        );
        expect(fresh.verification.passed, isTrue);
        final store = fresh as Sqlite3mcEncryptedStore;
        await _insertProfile(store, 'profile-1');
        expect(await _profileCount(store), 1);
        await fresh.dispose();

        // The on-disk file must not be a plaintext SQLite database.
        final File dbFile = File('${dir.path}/forge.sqlite');
        expect(dbFile.existsSync(), isTrue);
        final List<int> header = dbFile.readAsBytesSync().take(16).toList();
        expect(header, isNot(equals('SQLite format 3\u0000'.codeUnits)));

        // Reopen existing ciphertext with the correct key.
        final opener2 = Sqlite3mcEncryptedStoreOpener(
          repositoryFactories: <Type, RepositoryFactory>{},
        );
        final EncryptedStore reopened = await opener2.open(
          EncryptedStoreRequest(
            generationDirectory: dir.path,
            schemaVersion: 14,
            keyLease: _RawKeyLease(_key(1)),
            expectFreshStore: false,
          ),
        );
        expect(reopened.verification.passed, isTrue);
        expect(await _profileCount(reopened as Sqlite3mcEncryptedStore), 1);
        await reopened.dispose();
      },
    );

    test('a wrong key fails verification without resetting data', () async {
      // Provision an encrypted store with data under key 1.
      final opener = Sqlite3mcEncryptedStoreOpener(
        repositoryFactories: <Type, RepositoryFactory>{},
      );
      final Sqlite3mcEncryptedStore store =
          await opener.open(
                EncryptedStoreRequest(
                  generationDirectory: dir.path,
                  schemaVersion: 14,
                  keyLease: _RawKeyLease(_key(1)),
                  expectFreshStore: true,
                ),
              )
              as Sqlite3mcEncryptedStore;
      await _insertProfile(store, 'profile-1');
      await store.dispose();

      // Attempt to open the SAME ciphertext with a WRONG key. This must report
      // failed verification (cipher/sentinel false), NOT throw and NOT reset.
      final opener2 = Sqlite3mcEncryptedStoreOpener(
        repositoryFactories: <Type, RepositoryFactory>{},
      );
      final EncryptedStore wrong = await opener2.open(
        EncryptedStoreRequest(
          generationDirectory: dir.path,
          schemaVersion: 14,
          keyLease: _RawKeyLease(_key(99)),
          expectFreshStore: false,
        ),
      );
      expect(wrong.verification.passed, isFalse);
      expect(wrong.verification.cipherConfigured, isFalse);
      expect(wrong.verification.sentinelAuthentic, isFalse);
      await wrong.dispose();

      // The original data survives: reopening with the correct key still reads
      // the row (R-SEC-001: a failed key never resets data).
      final opener3 = Sqlite3mcEncryptedStoreOpener(
        repositoryFactories: <Type, RepositoryFactory>{},
      );
      final EncryptedStore recovered = await opener3.open(
        EncryptedStoreRequest(
          generationDirectory: dir.path,
          schemaVersion: 14,
          keyLease: _RawKeyLease(_key(1)),
          expectFreshStore: false,
        ),
      );
      expect(recovered.verification.passed, isTrue);
      expect(await _profileCount(recovered as Sqlite3mcEncryptedStore), 1);
      await recovered.dispose();
    });
  });
}
