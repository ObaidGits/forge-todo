import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/security/app_lock.dart';
import 'package:forge/features/home/application/inbound_capture_service.dart';
import 'package:forge/features/home/domain/inbound_capture.dart';
import 'package:forge/features/home/presentation/home_providers.dart';
import 'package:forge/features/home/presentation/inbound_capture_providers.dart';

import '../tasks/task_test_support.dart';

/// Verifies the inbound capture controller wires the OS port to the validated,
/// lock-gated, idempotent pipeline and drives it end to end over a real command
/// bus (R-SEARCH-004, R-SEC-003, R-GEN-005).
///
/// **Validates: Requirements R-SEARCH-004, R-SEC-003, R-GEN-005**
void main() {
  late TaskHarness h;
  late _FakeCapturePort port;

  setUp(() async {
    h = await TaskHarness.open();
    port = _FakeCapturePort();
  });

  tearDown(() async {
    await port.dispose();
    await h.close();
  });

  ProviderContainer containerWith(AppLockGate gate) {
    final ProviderContainer container = ProviderContainer(
      overrides: [
        activeProfileProvider.overrideWithValue(h.profileId),
        quickCaptureAreaProvider.overrideWithValue(h.lifeAreaId),
        taskCommandServiceProvider.overrideWith((Ref ref) => h.service),
        appLockGateProvider.overrideWithValue(gate),
        inboundCapturePortProvider.overrideWithValue(port),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'processes an OS-delivered share intent into a committed task',
    () async {
      final ProviderContainer container = containerWith(
        AppLockGate(elapsed: () => Duration.zero, configured: true)
          ..markUnlocked(),
      );
      // Keep the controller alive so it subscribes to the port.
      final ProviderSubscription<CaptureOutcome?> sub = container.listen(
        inboundCaptureControllerProvider,
        (_, _) {},
      );
      addTearDown(sub.close);

      port.add(
        const InboundCaptureRequest(
          source: CaptureSource.shareIntent,
          deliveryId: 'shared-1',
          sharedText: 'Follow up with Dana',
        ),
      );
      await pumpEventQueue();

      expect(
        container.read(inboundCaptureControllerProvider),
        isA<CaptureCommitted>(),
      );
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM tasks WHERE title = 'Follow up with Dana'",
        ),
        1,
      );
    },
  );

  test(
    'withholds a delivery that arrives while the session is locked',
    () async {
      final ProviderContainer container = containerWith(
        AppLockGate(elapsed: () => Duration.zero, configured: true),
      );
      final ProviderSubscription<CaptureOutcome?> sub = container.listen(
        inboundCaptureControllerProvider,
        (_, _) {},
      );
      addTearDown(sub.close);

      port.add(
        const InboundCaptureRequest(
          source: CaptureSource.shareIntent,
          deliveryId: 'shared-locked',
          sharedText: 'Secret task',
        ),
      );
      await pumpEventQueue();

      expect(
        container.read(inboundCaptureControllerProvider),
        isA<CaptureGated>(),
      );
      expect(
        await h.scalar(
          "SELECT COUNT(*) FROM tasks WHERE title = 'Secret task'",
        ),
        0,
      );
    },
  );
}

final class _FakeCapturePort implements InboundCapturePort {
  final StreamController<InboundCaptureRequest> _controller =
      StreamController<InboundCaptureRequest>.broadcast();

  @override
  Stream<InboundCaptureRequest> get captures => _controller.stream;

  void add(InboundCaptureRequest request) => _controller.add(request);

  Future<void> dispose() => _controller.close();
}
