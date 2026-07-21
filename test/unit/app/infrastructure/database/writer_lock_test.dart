import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/writer_lock.dart';

import '../../../../helpers/helpers.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-DB-WRITERLOCK-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.1'),
  requirements: <RequirementId>[RequirementId('R-GEN-001')],
);

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('forge-lock-');
  });

  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  ProcessWriterLock buildLock({
    required DateTime Function() now,
    String bootSessionId = 'boot-1',
    int pid = 4242,
    Duration leaseTtl = const Duration(seconds: 30),
    required String Function() tokens,
  }) {
    return ProcessWriterLock(
      lockFile: File('${dir.path}/forge.writer.lock'),
      pid: pid,
      bootSessionId: bootSessionId,
      now: now,
      tokenFactory: tokens,
      leaseTtl: leaseTtl,
    );
  }

  String Function() sequentialTokens() {
    int index = 0;
    return () => 'token-${index++}';
  }

  testWithEvidence(
    _evidence('001'),
    'acquire writes lock metadata and dispose releases it',
    () async {
      final DateTime now = DateTime.utc(2026, 3, 1, 12);
      final ProcessWriterLock lock = buildLock(
        now: () => now,
        tokens: sequentialTokens(),
      );

      final WriterLockHandle handle = await lock.acquire();
      expect(handle.metadata.pid, 4242);
      expect(handle.metadata.bootSessionId, 'boot-1');
      expect(File('${dir.path}/forge.writer.lock').existsSync(), isTrue);

      await handle.dispose();
      expect(handle.isReleased, isTrue);
      expect(File('${dir.path}/forge.writer.lock').existsSync(), isFalse);
    },
  );

  testWithEvidence(
    _evidence('002'),
    'a live lock held by another owner is not stealable',
    () async {
      final DateTime now = DateTime.utc(2026, 3, 1, 12);
      final ProcessWriterLock first = buildLock(
        now: () => now,
        tokens: sequentialTokens(),
      );
      await first.acquire();

      final ProcessWriterLock second = buildLock(
        now: () => now,
        pid: 9999,
        tokens: sequentialTokens(),
      );
      await expectLater(second.acquire, throwsA(isA<WriterLockUnavailable>()));
    },
  );

  testWithEvidence(
    _evidence('003'),
    'an expired lease is recovered as stale',
    () async {
      DateTime now = DateTime.utc(2026, 3, 1, 12);
      final ProcessWriterLock holder = buildLock(
        now: () => now,
        leaseTtl: const Duration(seconds: 30),
        tokens: sequentialTokens(),
      );
      await holder.acquire();

      // No renewal; lease lapses.
      now = now.add(const Duration(seconds: 31));
      final ProcessWriterLock recovering = buildLock(
        now: () => now,
        pid: 5555,
        tokens: sequentialTokens(),
      );
      final WriterLockHandle stolen = await recovering.acquire();
      expect(stolen.metadata.pid, 5555);
    },
  );

  testWithEvidence(
    _evidence('004'),
    'a lock from a previous boot session is recovered as stale',
    () async {
      final DateTime now = DateTime.utc(2026, 3, 1, 12);
      final ProcessWriterLock beforeReboot = buildLock(
        now: () => now,
        bootSessionId: 'boot-old',
        tokens: sequentialTokens(),
      );
      await beforeReboot.acquire();

      final ProcessWriterLock afterReboot = buildLock(
        now: () => now,
        bootSessionId: 'boot-new',
        tokens: sequentialTokens(),
      );
      final WriterLockHandle stolen = await afterReboot.acquire();
      expect(stolen.metadata.bootSessionId, 'boot-new');
    },
  );

  testWithEvidence(
    _evidence('005'),
    'renew refreshes the lease so the lock keeps looking live',
    () async {
      DateTime now = DateTime.utc(2026, 3, 1, 12);
      final ProcessWriterLock lock = buildLock(
        now: () => now,
        leaseTtl: const Duration(seconds: 30),
        tokens: sequentialTokens(),
      );
      final WriterLockHandle handle = await lock.acquire();

      now = now.add(const Duration(seconds: 20));
      await handle.renew();
      expect(handle.metadata.renewedAtUtc, now);

      // A peer 20s later still sees a live lease because of the renewal.
      now = now.add(const Duration(seconds: 20));
      final ProcessWriterLock peer = buildLock(
        now: () => now,
        pid: 7777,
        tokens: sequentialTokens(),
      );
      await expectLater(peer.acquire, throwsA(isA<WriterLockUnavailable>()));
    },
  );

  testWithEvidence(
    _evidence('006'),
    'a malformed lock file is treated as recoverable',
    () async {
      final File lockFile = File('${dir.path}/forge.writer.lock');
      await lockFile.writeAsString('{ not valid json');

      final DateTime now = DateTime.utc(2026, 3, 1, 12);
      final ProcessWriterLock lock = buildLock(
        now: () => now,
        tokens: sequentialTokens(),
      );
      final WriterLockHandle handle = await lock.acquire();
      expect(handle.metadata.pid, 4242);
    },
  );
}
