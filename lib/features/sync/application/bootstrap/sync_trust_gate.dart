/// The precondition gate a device must pass before it may link to a backend
/// (R-SYNC-007, NFR-SEC-002).
///
/// Linking is only honest if the user has been shown the trust-model disclosure
/// (TLS in transit; not end-to-end encrypted; an operator can read content) and
/// the target backend is a validated, replaceable protocol-v2 backend. This
/// gate composes those two facts into a single [assertReadyToLink] check the
/// link/adoption flow runs before it creates or merges a remote profile.
///
/// It is pure application glue: no Drift/Flutter/Supabase imports, so the
/// linking precondition can be reasoned about and tested independently of any
/// backend adapter or UI.
library;

// Named constructor parameters use public names bound to private fields; the
// initializing-formal form would leak underscored parameter names into the API.
// ignore_for_file: prefer_initializing_formals

import 'package:forge/features/sync/domain/sync_backend_config.dart';
import 'package:forge/features/sync/domain/sync_trust_disclosure.dart';

/// Raised when a link is attempted before its preconditions are satisfied — the
/// trust disclosure has not been acknowledged for the current version, or the
/// target backend is not the configured/validated backend.
final class SyncTrustGateException implements Exception {
  const SyncTrustGateException(this.reason);

  final String reason;

  @override
  String toString() => 'SyncTrustGateException: $reason';
}

/// Reads the user's current trust-disclosure acknowledgement, if any. The
/// presentation layer records an acknowledgement once the user accepts the
/// disclosure; a signed-out/fresh install returns null.
abstract interface class TrustDisclosureAcknowledgementStore {
  /// The acknowledgement the user last recorded, or null if none.
  Future<SyncTrustDisclosureAcknowledgement?> read();
}

/// Enforces the disclosure + backend-config preconditions for linking.
final class SyncTrustGate {
  SyncTrustGate({
    required SyncBackendConfig backendConfig,
    required TrustDisclosureAcknowledgementStore acknowledgementStore,
    SyncTrustDisclosure disclosure = SyncTrustDisclosure.current,
  }) : _backendConfig = backendConfig,
       _acknowledgementStore = acknowledgementStore,
       _disclosure = disclosure {
    if (!_disclosure.isComplete) {
      throw const SyncTrustGateException(
        'The trust disclosure is incomplete and cannot gate linking.',
      );
    }
  }

  final SyncBackendConfig _backendConfig;
  final TrustDisclosureAcknowledgementStore _acknowledgementStore;
  final SyncTrustDisclosure _disclosure;

  /// The disclosure this gate presents.
  SyncTrustDisclosure get disclosure => _disclosure;

  /// The backend this gate authorises linking to.
  SyncBackendConfig get backendConfig => _backendConfig;

  /// Whether the current acknowledgement satisfies the disclosure in force.
  Future<bool> get isDisclosureAcknowledged async {
    final SyncTrustDisclosureAcknowledgement? ack = await _acknowledgementStore
        .read();
    return ack != null && ack.isCurrentFor(_disclosure);
  }

  /// Asserts the device may link to [backend]. Throws
  /// [SyncTrustGateException] when the backend does not match the configured
  /// backend or the trust disclosure has not been acknowledged for the current
  /// version. Callers run this before creating or merging a remote profile.
  Future<void> assertReadyToLink(String backend) async {
    if (backend != _backendConfig.backendId) {
      throw SyncTrustGateException(
        'Refusing to link backend "$backend"; this gate is configured for '
        '"${_backendConfig.backendId}".',
      );
    }
    if (!await isDisclosureAcknowledged) {
      throw const SyncTrustGateException(
        'The sync trust disclosure (TLS in transit; not end-to-end encrypted; '
        'an operator can read content) must be acknowledged before linking.',
      );
    }
  }
}
