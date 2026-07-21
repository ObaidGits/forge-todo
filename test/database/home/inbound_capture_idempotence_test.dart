import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/routing/uri_policy.dart';
import 'package:forge/core/security/app_lock.dart';
import 'package:forge/features/home/application/inbound_capture_service.dart';
import 'package:forge/features/home/domain/inbound_capture.dart';

import '../tasks/task_test_support.dart';

/// Database-backed proof that inbound quick capture commits idempotently
/// through the real command bus: a re-delivered share/intent never
/// double-creates (R-SEARCH-004, R-GEN-005).
///
/// **Validates: Requirements R-SEARCH-004, R-GEN-005**
void main() {
  late TaskHarness h;
  late InboundCaptureService service;

  setUp(() async {
    h = await TaskHarness.open();
    service = InboundCaptureService(uriPolicy: UriPolicy());
  });

  tearDown(() async {
    await h.close();
  });

  CaptureOwnership ownership() => CaptureOwnership(
    profileId: h.profileId,
    lifeAreaId: h.lifeAreaId,
    commands: h.service,
  );

  AppLockGate unlocked() =>
      AppLockGate(elapsed: () => Duration.zero, configured: true)
        ..markUnlocked();

  Future<CaptureOutcome> capture(String deliveryId) => service.capture(
    request: InboundCaptureRequest(
      source: CaptureSource.shareIntent,
      deliveryId: deliveryId,
      sharedText: 'Buy milk',
    ),
    ownership: ownership(),
    lock: unlocked(),
  );

  test(
    'a re-delivered intent replays the receipt and creates one task',
    () async {
      final CaptureOutcome first = await capture('share-123');
      final CaptureOutcome second = await capture('share-123');

      expect(first, isA<CaptureCommitted>());
      expect(second, isA<CaptureCommitted>());
      // The first commit is fresh; the re-delivery replays the stored receipt.
      expect((first as CaptureCommitted).replayed, isFalse);
      expect((second as CaptureCommitted).replayed, isTrue);
      // Exactly one task exists despite two deliveries.
      expect(
        await h.scalar("SELECT COUNT(*) FROM tasks WHERE title = 'Buy milk'"),
        1,
      );
    },
  );

  test('a distinct delivery id creates a separate task', () async {
    await capture('share-123');
    final CaptureOutcome other = await capture('share-999');

    expect((other as CaptureCommitted).replayed, isFalse);
    expect(
      await h.scalar("SELECT COUNT(*) FROM tasks WHERE title = 'Buy milk'"),
      2,
    );
  });

  test(
    'a capture withheld while locked commits after unlock without duplication',
    () async {
      final AppLockGate gate = AppLockGate(
        elapsed: () => Duration.zero,
        configured: true,
      );

      // Locked: the intent is withheld and nothing is written.
      final CaptureOutcome gated = await service.capture(
        request: const InboundCaptureRequest(
          source: CaptureSource.shareIntent,
          deliveryId: 'share-locked',
          sharedText: 'Buy milk',
        ),
        ownership: ownership(),
        lock: gate,
      );
      expect(gated, isA<CaptureGated>());
      expect(
        await h.scalar("SELECT COUNT(*) FROM tasks WHERE title = 'Buy milk'"),
        0,
      );

      // After unlock, the OS re-delivers the same intent and it commits once.
      gate.markUnlocked();
      final CaptureOutcome committed = await service.capture(
        request: const InboundCaptureRequest(
          source: CaptureSource.shareIntent,
          deliveryId: 'share-locked',
          sharedText: 'Buy milk',
        ),
        ownership: ownership(),
        lock: gate,
      );
      expect(committed, isA<CaptureCommitted>());
      expect((committed as CaptureCommitted).replayed, isFalse);
      expect(
        await h.scalar("SELECT COUNT(*) FROM tasks WHERE title = 'Buy milk'"),
        1,
      );
    },
  );
}
