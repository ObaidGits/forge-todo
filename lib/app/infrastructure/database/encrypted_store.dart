import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/security/key_vault.dart';

/// Request to open one encrypted generation store.
///
/// The [keyLease] is borrowed only for the duration of [EncryptedStoreOpener.open].
/// The opener copies the key into the cipher configuration and MUST NOT retain
/// the lease; the runtime disposes the lease immediately after open returns.
final class EncryptedStoreRequest {
  const EncryptedStoreRequest({
    required this.generationDirectory,
    required this.schemaVersion,
    required this.keyLease,
    required this.expectFreshStore,
  });

  /// Absolute path to the generation directory containing the store files.
  final String generationDirectory;

  final int schemaVersion;

  /// Borrowed key material for cipher configuration.
  final KeyLease keyLease;

  /// True when provisioning a brand-new empty store (no verification of a prior
  /// sentinel is expected); false when opening existing ciphertext.
  final bool expectFreshStore;
}

/// Result of the mandatory startup verification sequence.
///
/// Opening is only trustworthy when every check passes. Any failing check
/// forces non-destructive Recovery Mode; it never resets keys or data.
final class StoreVerification {
  const StoreVerification({
    required this.cipherConfigured,
    required this.sentinelAuthentic,
    required this.schemaCompatible,
    required this.integrityOk,
  });

  const StoreVerification.allPassed()
    : cipherConfigured = true,
      sentinelAuthentic = true,
      schemaCompatible = true,
      integrityOk = true;

  final bool cipherConfigured;
  final bool sentinelAuthentic;
  final bool schemaCompatible;
  final bool integrityOk;

  bool get passed =>
      cipherConfigured && sentinelAuthentic && schemaCompatible && integrityOk;

  /// First failing check name, for redacted diagnostics.
  String? get firstFailure {
    if (!cipherConfigured) {
      return 'cipher';
    }
    if (!sentinelAuthentic) {
      return 'sentinel';
    }
    if (!schemaCompatible) {
      return 'schema';
    }
    if (!integrityOk) {
      return 'integrity';
    }
    return null;
  }
}

/// An opened, verified encrypted store bound to one generation.
abstract interface class EncryptedStore implements AsyncResource {
  UnitOfWork get unitOfWork;

  StoreVerification get verification;
}

/// Boundary that opens a verified encrypted store for a generation.
///
/// The concrete production opener (a dedicated Drift isolate over an encrypted
/// SQLite provider) is kept strictly behind this port per ADR-0001, so no
/// domain/application code depends on cipher-specific APIs and the provider can
/// be selected/replaced once ADR-0001 is accepted.
abstract interface class EncryptedStoreOpener {
  Future<EncryptedStore> open(EncryptedStoreRequest request);
}
