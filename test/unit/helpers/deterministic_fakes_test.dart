import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/security/key_vault.dart';

import '../../helpers/helpers.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-REL-FOUNDATION-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('2.6'),
  requirements: <RequirementId>[RequirementId('NFR-REL-004')],
);

void main() {
  testWithEvidence(
    _evidence('001'),
    'fake wall clock advances deterministically and requires UTC',
    () {
      final FakeClock clock = FakeClock(
        initialUtc: DateTime.utc(2026, 3, 1, 12),
        timezoneIdentifier: 'Europe/London',
      );
      clock.advance(const Duration(minutes: 15));

      expect(clock.utcNow(), DateTime.utc(2026, 3, 1, 12, 15));
      expect(clock.timezoneId(), 'Europe/London');
      expect(() => clock.setUtc(DateTime(2026, 3, 1)), throwsArgumentError);
    },
  );

  testWithEvidence(
    _evidence('002'),
    'fake monotonic clock resets only across an explicit new boot',
    () {
      final FakeMonotonicClock clock = FakeMonotonicClock();
      clock.advance(const Duration(seconds: 9));
      expect(clock.now().elapsedSinceBoot, const Duration(seconds: 9));
      expect(
        () => clock.advance(const Duration(microseconds: -1)),
        throwsArgumentError,
      );

      clock.reboot(newBootId: 'test-boot-002');
      expect(clock.bootSessionId(), 'test-boot-002');
      expect(clock.now().elapsedSinceBoot, Duration.zero);
      expect(
        () => clock.reboot(newBootId: 'test-boot-002'),
        throwsArgumentError,
      );
    },
  );

  testWithEvidence(
    _evidence('003'),
    'deterministic ID generator is ordered and fails on exhaustion',
    () {
      final FakeIdGenerator generated = FakeIdGenerator.sequential(start: 10);
      expect(generated.uuidV7(), '018f0000-0000-7000-8000-00000000000a');
      expect(generated.uuidV7(), '018f0000-0000-7000-8000-00000000000b');
      expect(generated.generatedCount, 2);

      final FakeIdGenerator finite = FakeIdGenerator(<String>[
        '018f0000-0000-7000-8000-00000000002a',
      ]);
      expect(finite.uuidV7(), '018f0000-0000-7000-8000-00000000002a');
      expect(finite.uuidV7, throwsStateError);
      expect(
        () => FakeIdGenerator(<String>['not-a-uuid']),
        throwsFormatException,
      );
    },
  );

  testWithEvidence(
    _evidence('004'),
    'fake key vault leases copies and zeroizes disposed leases',
    () async {
      final FakeKeyVault vault = FakeKeyVault.available(<int>[1, 2, 3]);
      final FakeKeyLease first = await vault.release();
      final List<int> exposed = first.copyBytes();
      exposed[0] = 99;
      final FakeKeyLease second = await vault.release();

      expect(second.copyBytes(), <int>[1, 2, 3]);
      await first.dispose();
      expect(first.copyBytes, throwsStateError);
      expect(vault.releaseCount, 2);
    },
  );

  testWithEvidence(
    _evidence('005'),
    'fake key vault never creates replacement key for existing ciphertext',
    () {
      final FakeKeyVault vault = FakeKeyVault.absent(
        encryptedStoreExists: true,
      );
      expect(
        () => vault.create(<int>[4, 5, 6]),
        throwsA(isA<KeyReleaseUnavailable>()),
      );
      expect(vault.state, KeyVaultState.recoveryRequired);
    },
  );

  testWithEvidence(
    _evidence('006'),
    'fake scheduler orders equal instants by stable ID and models revocation',
    () async {
      final FakeScheduler<String> scheduler = FakeScheduler<String>();
      final DateTime due = DateTime.utc(2026, 3, 2, 9);
      await scheduler.schedule(
        ScheduledItem<String>(id: 'b', dueAtUtc: due, payload: 'second'),
      );
      await scheduler.schedule(
        ScheduledItem<String>(id: 'a', dueAtUtc: due, payload: 'first'),
      );
      expect(
        scheduler.dueAt(due).map((ScheduledItem<String> item) => item.id),
        <String>['a', 'b'],
      );

      scheduler.setPermission(FakeSchedulerPermission.revoked);
      await expectLater(
        scheduler.schedule(
          ScheduledItem<String>(id: 'c', dueAtUtc: due, payload: 'blocked'),
        ),
        throwsStateError,
      );
    },
  );
}
