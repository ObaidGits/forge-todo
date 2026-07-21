import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/active_generation_pointer.dart';
import 'package:forge/app/infrastructure/database/database_runtime.dart';
import 'package:forge/app/infrastructure/database/encrypted_store.dart';
import 'package:forge/app/infrastructure/database/recovery_mode.dart';
import 'package:forge/app/infrastructure/database/writer_lock.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/id.dart';

import '../../../../helpers/helpers.dart';

EvidenceMetadata _evidence(
  String suffix, {
  List<String> requirements = const <String>['R-GEN-001'],
}) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-DB-RUNTIME-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.1'),
  requirements: requirements
      .map((String id) => RequirementId(id))
      .toList(growable: false),
);

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('forge-runtime-');
  });

  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  DatabaseRuntimePaths paths() => DatabaseRuntimePaths(baseDirectory: dir.path);

  DatabaseGeneration initialGeneration() =>
      DatabaseGeneration(id: GenerationId('generation-0001'), schemaVersion: 1);

  ForgeDatabaseRuntimeFactory factory({
    required FakeKeyVault vault,
    required FakeEncryptedStoreOpener opener,
    String bootSessionId = 'boot-1',
  }) {
    return ForgeDatabaseRuntimeFactory(
      paths: paths(),
      keyVault: vault,
      opener: opener,
      clock: FakeClock(initialUtc: DateTime.utc(2026, 3, 1, 12)),
      monotonicClock: FakeMonotonicClock(bootId: bootSessionId),
      idGenerator: FakeIdGenerator.sequential(start: 1),
      initialGeneration: initialGeneration(),
      processId: 4242,
    );
  }

  File pointerFile() => File('${dir.path}/active_generation.json');
  File lockFile() => File('${dir.path}/forge.writer.lock');

  testWithEvidence(
    _evidence('001', requirements: <String>['R-GEN-001', 'R-SEC-002']),
    'fresh bootstrap opens, verifies, publishes the pointer, and is ready',
    () async {
      final FakeKeyVault vault = FakeKeyVault.available(<int>[
        7,
        8,
        9,
      ], encryptedStoreExists: false);
      final FakeEncryptedStoreOpener opener = FakeEncryptedStoreOpener();
      final ForgeDatabaseRuntime runtime = await factory(
        vault: vault,
        opener: opener,
      ).open();

      expect(runtime.state, DatabaseRuntimeState.ready);
      expect(runtime.activeGeneration.id.value, 'generation-0001');
      expect(runtime.unitOfWork, isNotNull);
      expect(opener.lastRequest!.expectFreshStore, isTrue);
      expect(opener.leaseWasLiveAtOpen, isTrue);
      expect(opener.observedKeyBytes, <int>[7, 8, 9]);
      // The pointer is published only after successful verification.
      expect(pointerFile().existsSync(), isTrue);
      final ActiveGenerationRecord? published = await ActiveGenerationPointer(
        pointerFile: pointerFile(),
      ).read();
      expect(published!.generation.id.value, 'generation-0001');

      await runtime.dispose();
      expect(runtime.state, DatabaseRuntimeState.closed);
    },
  );

  testWithEvidence(
    _evidence('002', requirements: <String>['R-SEC-002']),
    'the borrowed key lease is disposed immediately after open',
    () async {
      final FakeKeyVault vault = FakeKeyVault.available(<int>[
        1,
        2,
      ], encryptedStoreExists: false);
      final FakeEncryptedStoreOpener opener = FakeEncryptedStoreOpener();
      await factory(vault: vault, opener: opener).open();

      expect(opener.lastRequest!.keyLease.isDisposed, isTrue);
    },
  );

  testWithEvidence(
    _evidence('003'),
    'existing generation bootstrap reuses the pointer without rewriting it',
    () async {
      await ActiveGenerationPointer(pointerFile: pointerFile()).switchTo(
        ActiveGenerationRecord(
          generation: DatabaseGeneration(
            id: GenerationId('gen-existing'),
            schemaVersion: 3,
          ),
          directoryName: 'generation-0007',
        ),
      );
      final FakeKeyVault vault = FakeKeyVault.available(<int>[
        5,
      ], encryptedStoreExists: true);
      final FakeEncryptedStoreOpener opener = FakeEncryptedStoreOpener();
      final ForgeDatabaseRuntime runtime = await factory(
        vault: vault,
        opener: opener,
      ).open();

      expect(runtime.activeGeneration.id.value, 'gen-existing');
      expect(runtime.activeGeneration.schemaVersion, 3);
      expect(opener.lastRequest!.expectFreshStore, isFalse);
      expect(
        opener.lastRequest!.generationDirectory.endsWith('generation-0007'),
        isTrue,
      );
      await runtime.dispose();
    },
  );

  testWithEvidence(
    _evidence('004', requirements: <String>['R-SEC-001', 'R-SEC-002']),
    'existing ciphertext with an unavailable key enters Recovery Mode',
    () async {
      final FakeKeyVault vault = FakeKeyVault.available(<int>[
        1,
      ], encryptedStoreExists: true)..lock();
      final FakeEncryptedStoreOpener opener = FakeEncryptedStoreOpener();
      final ForgeDatabaseRuntime runtime = await factory(
        vault: vault,
        opener: opener,
      ).open();

      expect(runtime.state, DatabaseRuntimeState.recoveryRequired);
      expect(runtime.recovery!.reason, RecoveryReason.keyUnavailable);
      // No store was opened, and no replacement key was created.
      expect(opener.openCount, 0);
      expect(vault.state.name, 'locked');
      expect(() => runtime.activeGeneration, throwsStateError);
      expect(() => runtime.unitOfWork, throwsStateError);
    },
  );

  testWithEvidence(
    _evidence('005'),
    'a corrupt active-generation pointer enters Recovery Mode',
    () async {
      await pointerFile().writeAsString('{ truncated pointer');
      final FakeKeyVault vault = FakeKeyVault.available(<int>[
        1,
      ], encryptedStoreExists: true);
      final FakeEncryptedStoreOpener opener = FakeEncryptedStoreOpener();
      final ForgeDatabaseRuntime runtime = await factory(
        vault: vault,
        opener: opener,
      ).open();

      expect(runtime.state, DatabaseRuntimeState.recoveryRequired);
      expect(runtime.recovery!.reason, RecoveryReason.pointerCorrupt);
      expect(opener.openCount, 0);
    },
  );

  testWithEvidence(
    _evidence('006', requirements: <String>['R-SEC-002']),
    'failed verification enters Recovery Mode and releases store and lock',
    () async {
      final FakeKeyVault vault = FakeKeyVault.available(<int>[
        1,
      ], encryptedStoreExists: false);
      final FakeEncryptedStoreOpener opener = FakeEncryptedStoreOpener(
        verification: const StoreVerification(
          cipherConfigured: true,
          sentinelAuthentic: false,
          schemaCompatible: true,
          integrityOk: true,
        ),
      );
      final ForgeDatabaseRuntime runtime = await factory(
        vault: vault,
        opener: opener,
      ).open();

      expect(runtime.state, DatabaseRuntimeState.recoveryRequired);
      expect(runtime.recovery!.reason, RecoveryReason.verificationFailed);
      expect(runtime.recovery!.detail, 'sentinel');
      // The lock must be released so a repair/restore flow can proceed.
      expect(lockFile().existsSync(), isFalse);
    },
  );

  testWithEvidence(
    _evidence('007'),
    'an open failure enters Recovery Mode and releases the lock',
    () async {
      final FakeKeyVault vault = FakeKeyVault.available(<int>[
        1,
      ], encryptedStoreExists: true);
      final FakeEncryptedStoreOpener opener = FakeEncryptedStoreOpener(
        failOpen: true,
      );
      final ForgeDatabaseRuntime runtime = await factory(
        vault: vault,
        opener: opener,
      ).open();

      expect(runtime.state, DatabaseRuntimeState.recoveryRequired);
      expect(runtime.recovery!.reason, RecoveryReason.openFailed);
      expect(lockFile().existsSync(), isFalse);
    },
  );

  testWithEvidence(
    _evidence('008', requirements: <String>['R-GEN-001']),
    'a second live instance cannot acquire the writer lock',
    () async {
      final FakeKeyVault vault = FakeKeyVault.available(<int>[
        1,
      ], encryptedStoreExists: false);
      final FakeEncryptedStoreOpener opener = FakeEncryptedStoreOpener();
      final ForgeDatabaseRuntime first = await factory(
        vault: vault,
        opener: opener,
      ).open();
      expect(first.state, DatabaseRuntimeState.ready);

      final FakeKeyVault vault2 = FakeKeyVault.available(<int>[
        1,
      ], encryptedStoreExists: true);
      final FakeEncryptedStoreOpener opener2 = FakeEncryptedStoreOpener();
      await expectLater(
        factory(vault: vault2, opener: opener2).open,
        throwsA(isA<WriterLockUnavailable>()),
      );
      await first.dispose();
    },
  );

  testWithEvidence(
    _evidence('009'),
    'a fresh install with no provisioned key is a bootstrap error, not a reset',
    () async {
      final FakeKeyVault vault = FakeKeyVault.absent(
        encryptedStoreExists: false,
      );
      final FakeEncryptedStoreOpener opener = FakeEncryptedStoreOpener();
      await expectLater(
        factory(vault: vault, opener: opener).open,
        throwsA(isA<DatabaseBootstrapException>()),
      );
    },
  );

  testWithEvidence(
    _evidence('010', requirements: <String>['R-GEN-001']),
    'headless work runs bounded and disposes the runtime and lock',
    () async {
      final FakeKeyVault vault = FakeKeyVault.available(<int>[
        1,
      ], encryptedStoreExists: false);
      final FakeEncryptedStoreOpener opener = FakeEncryptedStoreOpener();
      final ForgeDatabaseRuntimeFactory f = factory(
        vault: vault,
        opener: opener,
      );

      final String result = await f.runHeadless<String>((
        ForgeDatabaseRuntime runtime,
      ) async {
        expect(runtime.state, DatabaseRuntimeState.ready);
        return 'done';
      }, deadline: const Duration(seconds: 5));

      expect(result, 'done');
      expect(lockFile().existsSync(), isFalse);
    },
  );

  testWithEvidence(
    _evidence('011', requirements: <String>['R-SEC-001']),
    'headless work refuses to run when the runtime is in Recovery Mode',
    () async {
      final FakeKeyVault vault = FakeKeyVault.available(<int>[
        1,
      ], encryptedStoreExists: true)..lock();
      final FakeEncryptedStoreOpener opener = FakeEncryptedStoreOpener();
      final ForgeDatabaseRuntimeFactory f = factory(
        vault: vault,
        opener: opener,
      );

      await expectLater(
        () => f.runHeadless<void>(
          (ForgeDatabaseRuntime runtime) async {},
          deadline: const Duration(seconds: 5),
        ),
        throwsA(isA<HeadlessRuntimeUnavailable>()),
      );
      expect(lockFile().existsSync(), isFalse);
    },
  );

  testWithEvidence(
    _evidence('012', requirements: <String>['R-GEN-001']),
    'headless work that exceeds its deadline still disposes and releases',
    () async {
      final FakeKeyVault vault = FakeKeyVault.available(<int>[
        1,
      ], encryptedStoreExists: false);
      final FakeEncryptedStoreOpener opener = FakeEncryptedStoreOpener();
      final ForgeDatabaseRuntimeFactory f = factory(
        vault: vault,
        opener: opener,
      );

      await expectLater(
        () => f.runHeadless<void>(
          (ForgeDatabaseRuntime runtime) => Completer<void>().future,
          deadline: const Duration(milliseconds: 50),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(lockFile().existsSync(), isFalse);
    },
  );

  testWithEvidence(_evidence('013'), 'dispose is idempotent', () async {
    final FakeKeyVault vault = FakeKeyVault.available(<int>[
      1,
    ], encryptedStoreExists: false);
    final FakeEncryptedStoreOpener opener = FakeEncryptedStoreOpener();
    final ForgeDatabaseRuntime runtime = await factory(
      vault: vault,
      opener: opener,
    ).open();

    await runtime.dispose();
    await runtime.dispose();
    expect(runtime.state, DatabaseRuntimeState.closed);
  });
}
