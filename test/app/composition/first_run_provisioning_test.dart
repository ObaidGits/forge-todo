import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/composition/first_run_provisioning.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/encrypted/sqlite3mc_encrypted_store.dart';
import 'package:forge/app/infrastructure/database/encrypted_store.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/id/uuid_v7_generator.dart';
import 'package:forge/app/infrastructure/system_clock.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/security/key_vault.dart';
import 'package:forge/features/areas/infrastructure/area_repository_factories.dart';
import 'package:forge/features/areas/infrastructure/life_area_command_service_drift.dart';

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

Uint8List _key() =>
    Uint8List.fromList(List<int>.generate(32, (int i) => (i * 3 + 5) & 0xff));

Future<Sqlite3mcEncryptedStore> _open(
  String generationDir, {
  required bool fresh,
}) async {
  final opener = Sqlite3mcEncryptedStoreOpener(
    repositoryFactories: <Type, RepositoryFactory>{...areaRepositoryFactories},
  );
  final EncryptedStore store = await opener.open(
    EncryptedStoreRequest(
      generationDirectory: generationDir,
      schemaVersion: 14,
      keyLease: _RawKeyLease(_key()),
      expectFreshStore: fresh,
    ),
  );
  return store as Sqlite3mcEncryptedStore;
}

FirstRunProvisioning _provisioning(Sqlite3mcEncryptedStore store) {
  final Clock clock = const SystemClock.utc();
  final UuidV7Generator ids = UuidV7Generator(clock: clock);
  final ForgeCommandBus bus = ForgeCommandBus(
    unitOfWork: store.unitOfWork,
    clock: clock,
    afterCommit: AfterCommitDispatcher(),
  );
  return FirstRunProvisioning(
    clock: clock,
    idGenerator: ids,
    areaCommands: DriftLifeAreaCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
    ),
  );
}

Future<int> _scalar(Sqlite3mcEncryptedStore store, String sql) async {
  final rows = await store.database.customSelect(sql).get();
  return rows.single.data.values.first! as int;
}

void main() {
  group('FirstRunProvisioning', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('forge-provision-');
    });
    tearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    test(
      'a fresh store ends with one profile and seven default areas',
      () async {
        final store = await _open(dir.path, fresh: true);
        final ProvisionedProfile result = await _provisioning(store).ensure(
          db: store.database,
          bindActiveProfile: store.bindActiveProfile,
        );

        expect(result.wasSeeded, isTrue);
        expect(await _scalar(store, 'SELECT count(*) FROM profiles'), 1);
        expect(await _scalar(store, 'SELECT count(*) FROM life_areas'), 7);
        expect(
          await _scalar(
            store,
            'SELECT count(*) FROM life_areas WHERE is_default = 1',
          ),
          1,
        );

        // Areas are in canonical order and the default is the first (Career).
        final rows = await store.database
            .customSelect(
              'SELECT name, is_default FROM life_areas ORDER BY rank ASC',
            )
            .get();
        expect(
          rows.map((r) => r.read<String>('name')).toList(),
          FirstRunProvisioning.defaultLifeAreaNames,
        );
        expect(rows.first.read<int>('is_default'), 1);

        // The default area is the one bound for quick capture.
        final defaultName =
            (await store.database
                    .customSelect(
                      'SELECT name FROM life_areas WHERE id = ?',
                      variables: [
                        // ignore: prefer_const_constructors
                        Variable<String>(result.defaultAreaId.value),
                      ],
                    )
                    .getSingle())
                .read<String>('name');
        expect(defaultName, 'Career');

        await store.dispose();
      },
    );

    test('is idempotent on a second ensure and after reopen', () async {
      final store = await _open(dir.path, fresh: true);
      final first = await _provisioning(
        store,
      ).ensure(db: store.database, bindActiveProfile: store.bindActiveProfile);
      expect(first.wasSeeded, isTrue);

      // Second ensure on the same open store must not re-seed.
      final second = await _provisioning(
        store,
      ).ensure(db: store.database, bindActiveProfile: store.bindActiveProfile);
      expect(second.wasSeeded, isFalse);
      expect(second.profileId.value, first.profileId.value);
      expect(await _scalar(store, 'SELECT count(*) FROM profiles'), 1);
      expect(await _scalar(store, 'SELECT count(*) FROM life_areas'), 7);
      await store.dispose();

      // Reopen the same ciphertext and ensure again: still not re-seeded.
      final reopened = await _open(dir.path, fresh: false);
      final third = await _provisioning(reopened).ensure(
        db: reopened.database,
        bindActiveProfile: reopened.bindActiveProfile,
      );
      expect(third.wasSeeded, isFalse);
      expect(third.profileId.value, first.profileId.value);
      expect(await _scalar(reopened, 'SELECT count(*) FROM profiles'), 1);
      expect(await _scalar(reopened, 'SELECT count(*) FROM life_areas'), 7);
      await reopened.dispose();
    });
  });
}
