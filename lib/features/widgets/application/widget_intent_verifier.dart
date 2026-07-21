/// Verifies untrusted widget intents before any command runs (R-WIDGET-003).
///
/// Spoof resistance is enforced here. An inbound [WidgetIntent] must clear every
/// check to become a [VerifiedWidgetCommand]:
///
///   1. **Well-formed:** a known action bound to a non-empty target.
///   2. **Profile binding:** the intent's profile must equal the active local
///      profile, so an intent minted for another profile cannot drive a write.
///   3. **Authentication:** the signed token must match the canonical payload,
///      so a tampered or forged intent is rejected.
///   4. **Freshness:** the timestamp must fall inside the accepted window, so a
///      replayed or stale token is rejected (a legitimate double-tap within the
///      window is still safe — idempotency handles it downstream).
library;

import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/widgets/application/widget_bridge.dart';
import 'package:forge/features/widgets/domain/widget_intent.dart';

final class WidgetIntentVerifier {
  const WidgetIntentVerifier({
    required this.signer,
    required this.clock,
    required this.activeProfileId,
    this.freshnessWindow = const Duration(minutes: 5),
    this.futureTolerance = const Duration(seconds: 30),
  });

  final WidgetIntentSigner signer;
  final Clock clock;
  final ProfileId activeProfileId;

  /// How old an intent may be before it is rejected as expired/replayed.
  final Duration freshnessWindow;

  /// How far in the future an intent's timestamp may be (clock skew tolerance).
  final Duration futureTolerance;

  /// Verifies [intent], returning a [VerifiedWidgetCommand] or a stable failure.
  Result<VerifiedWidgetCommand> verify(WidgetIntent intent) {
    if (!intent.isWellFormed) {
      return _reject(WidgetIntentRejection.malformed);
    }

    // Profile binding first: never even hash a foreign-profile intent.
    if (intent.profileId != activeProfileId.value) {
      return _reject(WidgetIntentRejection.profileMismatch);
    }

    final String canonical = intent.canonicalPayload();
    if (!signer.verify(canonical, intent.token)) {
      return _reject(WidgetIntentRejection.invalidSignature);
    }

    final int nowMicros = clock.utcNow().toUtc().microsecondsSinceEpoch;
    final int ageMicros = nowMicros - intent.issuedAtUtcMicros;
    if (ageMicros < -futureTolerance.inMicroseconds) {
      return _reject(WidgetIntentRejection.future);
    }
    if (ageMicros > freshnessWindow.inMicroseconds) {
      return _reject(WidgetIntentRejection.expired);
    }

    return Success<VerifiedWidgetCommand>(
      VerifiedWidgetCommand(
        intentId: intent.intentId,
        profileId: intent.profileId,
        action: intent.action,
        surfaceWire: intent.surfaceWire,
        targetEntityId: intent.targetEntityId,
        canonicalPayload: canonical,
      ),
    );
  }

  static Result<VerifiedWidgetCommand> _reject(WidgetIntentRejection reason) {
    final FailureKind kind = switch (reason) {
      WidgetIntentRejection.invalidSignature ||
      WidgetIntentRejection.profileMismatch => FailureKind.permission,
      WidgetIntentRejection.expired ||
      WidgetIntentRejection.future ||
      WidgetIntentRejection.malformed => FailureKind.validation,
    };
    return Failed<VerifiedWidgetCommand>(
      Failure(
        kind: kind,
        code: 'widget.intent_rejected.${reason.name}',
        safeMessageKey: 'error.widget.intent_rejected',
        retryable: false,
        redactedCause: reason.name,
      ),
    );
  }
}
