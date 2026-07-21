import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/focus/domain/distraction_copy.dart';

/// Capability-gated distraction copy proofs (R-FOCUS-006).
///
/// Forge SHALL NOT claim to block distractions unless an independently
/// permissioned platform capability is active.
///
/// **Validates: Requirements R-FOCUS-006**
void main() {
  group('[TEST-FOCUS-DISTRACTION-COPY][MVP][TASK-7.3][R-FOCUS-006] distraction '
      'claims are capability gated', () {
    test('an active blocking capability may claim blocking', () {
      expect(
        DistractionCopy.mayClaimBlocking(blockingCapabilityActive: true),
        isTrue,
      );
      expect(
        DistractionCopy.messageKey(blockingCapabilityActive: true),
        DistractionCopy.blockingActiveKey,
      );
    });

    test('without the capability Forge never claims blocking', () {
      expect(
        DistractionCopy.mayClaimBlocking(blockingCapabilityActive: false),
        isFalse,
      );
      expect(
        DistractionCopy.messageKey(blockingCapabilityActive: false),
        DistractionCopy.blockingUnavailableKey,
      );
      // The two copy keys are distinct so the UI cannot conflate them.
      expect(
        DistractionCopy.blockingActiveKey,
        isNot(DistractionCopy.blockingUnavailableKey),
      );
    });
  });
}
