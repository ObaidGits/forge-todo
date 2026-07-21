import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/active_generation_pointer.dart';
import 'package:forge/app/infrastructure/database/database_runtime.dart';
import 'package:forge/app/infrastructure/database/encrypted_store.dart';
import 'package:forge/app/infrastructure/database/recovery_mode.dart';
import 'package:forge/app/infrastructure/database/writer_lock.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/id.dart';

import '../../helpers/helpers.dart';

/// Wave 2 hardening — generation switch, ProviderScope rebinding, wrong-key
/// store open, and abrupt-termination boundaries at the runtime layer.
///
/// The [ForgeDatabaseRuntime] exclusively owns the writer lock, encrypted
/// store, and active generation. A generation switch (migration/restore
/// activation) is realised by closing command admission, disposing the runtime
/// (and with it its ProviderScope), atomically replacing the active-generation
/// pointer, then reopening — which rebinds every provider to exactly one fully
/// verified generation. These suites drive that dispose-and-rebuild path over
/// the real runtime factory and assert no consumer ever observes a blend of
/// two generations, that a wrong key routes to non-destructive Recovery Mode,
/// and that an abrupt termination at a switch boundary always leaves either the
/// old or the new valid generation.
EvidenceMetadata _evidence(
  String suffix, {
  List<String> requirements = const <String>['NFR-REL-002'],
}) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-DB-GENSWITCH-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.11'),
  requirements: requirements
      .map((String id) => RequirementId(id))
      .toList(growable: false),
);

/// An [EncryptedStoreOpener] double that models a real cipher: it only opens a
/// trustworthy store when the borrowed key lease matches the key the store was
/// provisioned with. A mismatched (wrong) key yields a store whose cipher check
/// fails, exactly as SQLCipher/sqlite3mc reports an undecryptable database.
///
/// It also records the generation directory of the most recent open so a test
/// can prove which generation a rebuilt runtime bound to.
final class KeyAwareStoreOpener implements EncryptedStoreOpener {
  KeyAwareStoreOpener({required List<int> correctKey})
    : _correctKey = Uint8List.fromList(correctKey);

  final Uint8List _correctKey;

  int openCount = 0;
  String? lastGenerationDirectory;

  @override
  Future<EncryptedStore> open(EncryptedStoreRequest request) async {
    openCount += 1;
    lastGenerationDirectory = request.generationDirectory;
    final Uint8List presented = request.keyLease.copyBytes();
    final bool keyMatches = _listEquals(presented, _correctKey);
    return FakeEncryptedStore(
      unitOfWork: FakeUnitOfWork(repositories: const <Type, Object>{}),
      // A wrong key cannot configure the cipher; every other check is moot.
      verification: keyMatches
          ? const StoreVerification.allPassed()
          : const StoreVerification(
              cipherConfigured: false,
              sentinelAuthentic: false,
              schemaCompatible: false,
              integrityOk: false,
            ),
    );
  }

  static bool _listEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('forge-genswitch-');
  });

  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  DatabaseRuntimePaths paths() => DatabaseRuntimePaths(baseDirectory: dir.path);

  ActiveGenerationPointer pointer() => ActiveGenerationPointer(
    pointerFile: File('${dir.path}/active_generation.json'),
  );

  File lockFile() => File('${dir.path}/forge.writer.lock');

  ForgeDatabaseRuntimeFactory factory({
    required FakeKeyVault vault,
    required EncryptedStoreOpener opener,
    String bootSessionId = 'boot-1',
  }) {
    return ForgeDatabaseRuntimeFactory(
      paths: paths(),
      keyVault: vault,
      opener: opener,
      clock: FakeClock(initialUtc: DateTime.utc(2026, 3, 1, 12)),
      monotonicClock: FakeMonotonicClock(bootId: bootSessionId),
      idGenerator: FakeIdGenerator.sequential(start: 1),
      initialGeneration: DatabaseGeneration(
        id: GenerationId('generation-0001'),
        schemaVersion: 1,
      ),
      processId: 4242,
    );
  }

  Future<void> publishPointer({
    required String generationId,
    required int schemaVersion,
    required String directoryName,
  }) async {
    await pointer().switchTo(
      ActiveGenerationRecord(
        generation: DatabaseGeneration(
          id: GenerationId(generationId),
          schemaVersion: schemaVersion,
        ),
        directoryName: directoryName,
      ),
    );
  }

  group('generation switch via dispose-and-rebuild', () {
    testWithEvidence(
      _evidence('001', requirements: <String>['NFR-REL-002', 'R-SYNC-006']),
      'disposing the runtime then switching the pointer rebinds a reopened '
      'runtime to exactly the new generation',
      () async {
        await publishPointer(
          generationId: 'gen-A',
          schemaVersion: 1,
          directoryName: 'generation-A',
        );
        final FakeKeyVault vault = FakeKeyVault.available(<int>[
          1,
          2,
          3,
        ], encryptedStoreExists: true);
        final KeyAwareStoreOpener opener = KeyAwareStoreOpener(
          correctKey: <int>[1, 2, 3],
        );

        // Bind to the prior generation A.
        final ForgeDatabaseRuntime a = await factory(
          vault: vault,
          opener: opener,
        ).open();
        expect(a.state, DatabaseRuntimeState.ready);
        expect(a.activeGeneration.id.value, 'gen-A');
        expect(a.activeGeneration.schemaVersion, 1);
        expect(opener.lastGenerationDirectory, endsWith('generation-A'));

        // A generation switch closes command admission first.
        a.enterMaintenance();
        expect(a.state, DatabaseRuntimeState.maintenance);
        expect(() => a.unitOfWork, throwsStateError);

        // Dispose the runtime (and its ProviderScope) before the pointer moves.
        await a.dispose();
        expect(a.state, DatabaseRuntimeState.closed);
        expect(lockFile().existsSync(), isFalse);

        // The activation atomically replaces the pointer with generation B.
        await publishPointer(
          generationId: 'gen-B',
          schemaVersion: 2,
          directoryName: 'generation-B',
        );

        // Rebuild: reopening rebinds to the new generation and nothing else.
        final ForgeDatabaseRuntime b = await factory(
          vault: vault,
          opener: opener,
        ).open();
        expect(b.state, DatabaseRuntimeState.ready);
        expect(b.activeGeneration.id.value, 'gen-B');
        expect(b.activeGeneration.schemaVersion, 2);
        expect(opener.lastGenerationDirectory, endsWith('generation-B'));

        // The disposed runtime is closed and no longer serves a unit of work,
        // so no consumer can write through the old generation after the switch.
        expect(a.state, DatabaseRuntimeState.closed);
        expect(() => a.unitOfWork, throwsStateError);

        await b.dispose();
      },
    );

    testWithEvidence(
      _evidence('002', requirements: <String>['NFR-REL-002', 'R-GEN-001']),
      'a rebuild attempted before the prior runtime is disposed is refused by '
      'the writer lock, so two generations are never live at once',
      () async {
        await publishPointer(
          generationId: 'gen-A',
          schemaVersion: 1,
          directoryName: 'generation-A',
        );
        final FakeKeyVault vault = FakeKeyVault.available(<int>[
          1,
          2,
          3,
        ], encryptedStoreExists: true);
        final KeyAwareStoreOpener opener = KeyAwareStoreOpener(
          correctKey: <int>[1, 2, 3],
        );
        final ForgeDatabaseRuntime a = await factory(
          vault: vault,
          opener: opener,
        ).open();
        expect(a.state, DatabaseRuntimeState.ready);

        // Switching the pointer without disposing must not let a second
        // runtime open concurrently: the exclusive writer lock forbids it.
        await publishPointer(
          generationId: 'gen-B',
          schemaVersion: 2,
          directoryName: 'generation-B',
        );
        await expectLater(
          factory(vault: vault, opener: opener).open,
          throwsA(isA<WriterLockUnavailable>()),
        );

        // The live runtime is untouched and still bound to A.
        expect(a.activeGeneration.id.value, 'gen-A');
        await a.dispose();
      },
    );

    testWithEvidence(
      _evidence('003', requirements: <String>['NFR-REL-002']),
      'maintenance closes and resume reopens command admission around a switch',
      () async {
        await publishPointer(
          generationId: 'gen-A',
          schemaVersion: 1,
          directoryName: 'generation-A',
        );
        final FakeKeyVault vault = FakeKeyVault.available(<int>[
          1,
          2,
          3,
        ], encryptedStoreExists: true);
        final ForgeDatabaseRuntime a = await factory(
          vault: vault,
          opener: KeyAwareStoreOpener(correctKey: <int>[1, 2, 3]),
        ).open();

        expect(a.unitOfWork, isNotNull);
        a.enterMaintenance();
        expect(() => a.unitOfWork, throwsStateError);
        a.resume();
        expect(a.state, DatabaseRuntimeState.ready);
        expect(a.unitOfWork, isNotNull);
        await a.dispose();
      },
    );
  });

  group('wrong-key store open', () {
    testWithEvidence(
      _evidence('004', requirements: <String>['NFR-REL-002', 'R-SEC-001']),
      'opening existing ciphertext with a wrong key enters Recovery Mode and '
      'never resets the pointer, generation, or key',
      () async {
        // Provision a fresh, verified store with the correct key.
        final KeyAwareStoreOpener opener = KeyAwareStoreOpener(
          correctKey: <int>[1, 2, 3],
        );
        final FakeKeyVault provisioning = FakeKeyVault.available(<int>[
          1,
          2,
          3,
        ], encryptedStoreExists: false);
        final ForgeDatabaseRuntime first = await factory(
          vault: provisioning,
          opener: opener,
        ).open();
        expect(first.state, DatabaseRuntimeState.ready);
        final ActiveGenerationRecord? published = await pointer().read();
        expect(published, isNotNull);
        await first.dispose();

        // Reopen with a vault that releases the WRONG key bytes.
        final FakeKeyVault wrongKey = FakeKeyVault.available(<int>[
          9,
          9,
          9,
        ], encryptedStoreExists: true);
        final ForgeDatabaseRuntime second = await factory(
          vault: wrongKey,
          opener: opener,
        ).open();

        expect(second.state, DatabaseRuntimeState.recoveryRequired);
        expect(second.recovery!.reason, RecoveryReason.verificationFailed);
        expect(second.recovery!.detail, 'cipher');
        // Non-destructive: the pointer and generation survive untouched, the
        // vault is not mutated, and the lock is released for a repair flow.
        final ActiveGenerationRecord? after = await pointer().read();
        expect(after!.directoryName, published!.directoryName);
        expect(after.generation.id.value, published.generation.id.value);
        expect(wrongKey.state.name, 'available');
        expect(lockFile().existsSync(), isFalse);

        await second.dispose();
      },
    );

    testWithEvidence(
      _evidence('005', requirements: <String>['NFR-REL-002', 'R-SEC-001']),
      'the correct key reopens the same generation cleanly after a wrong-key '
      'recovery, proving nothing was destroyed',
      () async {
        final KeyAwareStoreOpener opener = KeyAwareStoreOpener(
          correctKey: <int>[4, 5, 6],
        );
        final ForgeDatabaseRuntime first = await factory(
          vault: FakeKeyVault.available(<int>[
            4,
            5,
            6,
          ], encryptedStoreExists: false),
          opener: opener,
        ).open();
        final String directory = (await pointer().read())!.directoryName;
        await first.dispose();

        // Wrong key -> recovery (no reset).
        final ForgeDatabaseRuntime recovery = await factory(
          vault: FakeKeyVault.available(<int>[0], encryptedStoreExists: true),
          opener: opener,
        ).open();
        expect(recovery.state, DatabaseRuntimeState.recoveryRequired);
        await recovery.dispose();

        // Correct key -> ready, same generation directory.
        final ForgeDatabaseRuntime repaired = await factory(
          vault: FakeKeyVault.available(<int>[
            4,
            5,
            6,
          ], encryptedStoreExists: true),
          opener: opener,
        ).open();
        expect(repaired.state, DatabaseRuntimeState.ready);
        expect((await pointer().read())!.directoryName, directory);
        await repaired.dispose();
      },
    );
  });

  group('abrupt termination at a switch boundary', () {
    testWithEvidence(
      _evidence('006', requirements: <String>['NFR-REL-002', 'NFR-REL-004']),
      'a crash (no dispose) after a pointer switch leaves the new valid '
      'generation, and the next boot recovers the stale lock and binds it',
      () async {
        await publishPointer(
          generationId: 'gen-A',
          schemaVersion: 1,
          directoryName: 'generation-A',
        );
        final FakeKeyVault vault = FakeKeyVault.available(<int>[
          1,
          2,
          3,
        ], encryptedStoreExists: true);
        final KeyAwareStoreOpener opener = KeyAwareStoreOpener(
          correctKey: <int>[1, 2, 3],
        );

        // Bind to A, then simulate an abrupt termination: do NOT dispose, so
        // the writer lock file is left behind under the current boot session.
        final ForgeDatabaseRuntime crashed = await factory(
          vault: vault,
          opener: opener,
          bootSessionId: 'boot-1',
        ).open();
        expect(crashed.state, DatabaseRuntimeState.ready);
        expect(lockFile().existsSync(), isTrue);

        // A maintenance process completed the activation to B while the crashed
        // instance's lock is now stale.
        await publishPointer(
          generationId: 'gen-B',
          schemaVersion: 2,
          directoryName: 'generation-B',
        );

        // The next boot (new boot session) recovers the stale lock and binds
        // exactly the new, valid generation — never a blend.
        final ForgeDatabaseRuntime rebooted = await factory(
          vault: vault,
          opener: opener,
          bootSessionId: 'boot-2',
        ).open();
        expect(rebooted.state, DatabaseRuntimeState.ready);
        expect(rebooted.activeGeneration.id.value, 'gen-B');
        expect(rebooted.activeGeneration.schemaVersion, 2);

        await rebooted.dispose();
        // Clean up the crashed instance's in-memory resources.
        await crashed.dispose();
      },
    );

    testWithEvidence(
      _evidence('007', requirements: <String>['NFR-REL-002', 'NFR-REL-004']),
      'a crash before any switch leaves the prior valid generation for the '
      'next boot',
      () async {
        await publishPointer(
          generationId: 'gen-A',
          schemaVersion: 1,
          directoryName: 'generation-A',
        );
        final FakeKeyVault vault = FakeKeyVault.available(<int>[
          1,
          2,
          3,
        ], encryptedStoreExists: true);
        final KeyAwareStoreOpener opener = KeyAwareStoreOpener(
          correctKey: <int>[1, 2, 3],
        );
        final ForgeDatabaseRuntime crashed = await factory(
          vault: vault,
          opener: opener,
          bootSessionId: 'boot-1',
        ).open();
        expect(crashed.activeGeneration.id.value, 'gen-A');

        final ForgeDatabaseRuntime rebooted = await factory(
          vault: vault,
          opener: opener,
          bootSessionId: 'boot-2',
        ).open();
        expect(rebooted.state, DatabaseRuntimeState.ready);
        expect(rebooted.activeGeneration.id.value, 'gen-A');
        expect(rebooted.activeGeneration.schemaVersion, 1);

        await rebooted.dispose();
        await crashed.dispose();
      },
    );
  });
}
