import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:forge/core/security/secure_key_store.dart';

/// Production adapter that implements the pure-Dart [SecureKeyStore] port over
/// the `flutter_secure_storage` plugin (libsecret on Linux, Keychain on Apple
/// platforms, DPAPI on Windows, Keystore on Android).
///
/// ## Why this is the only production wiring needed to activate the hardened vault
/// [SecureStorageKeyVault] depends solely on the [SecureKeyStore] port so its
/// R-SEC-001 no-replacement-key logic can be unit-tested without a live OS
/// keyring. This adapter is the thin, invariant-preserving bridge from that
/// port to the concrete plugin; wiring it (plus the composition-root decision
/// in `bootstrap.dart`) is all that is required to move the device key into the
/// OS secret service on a secret-service-enabled target.
///
/// ## The availability-vs-absence contract (R-SEC-001) — enforced here
/// The port draws a hard line between two outcomes the vault relies on:
///   * The store is reachable but simply holds no value for the key → the
///     plugin returns `null` and this adapter returns `null` unchanged. This is
///     a legitimate "no key yet" answer that the vault may treat as a fresh
///     install.
///   * The secret service itself cannot be reached or operated (no keyring
///     daemon on a headless box, a locked/absent keychain, a denied
///     entitlement, a `PlatformException`, a `MissingPluginException`, or any
///     other plugin throw) → this adapter translates the failure into
///     [SecureKeyStoreUnavailable]. It NEVER collapses an outage into `null`,
///     because doing so would let a transient keyring failure masquerade as a
///     fresh install and risk minting a replacement key over existing
///     ciphertext.
///
/// [write] and [delete] map every plugin failure to [SecureKeyStoreUnavailable]
/// for the same reason, so the composition root can fall back to the local file
/// vault (fail-safe) rather than proceed on a false success.
final class FlutterSecureKeyStore implements SecureKeyStore {
  /// Creates an adapter over an injected [FlutterSecureStorage]. Tests may
  /// inject a configured instance; production constructs the default below.
  FlutterSecureKeyStore({FlutterSecureStorage? storage})
    : _storage = storage ?? _defaultStorage();

  /// The plugin instance. Configured with explicit Linux libsecret options so
  /// the collection/schema is stable across runs on the current target.
  final FlutterSecureStorage _storage;

  /// Explicit Linux (libsecret) options. This version of the plugin exposes no
  /// additional Linux tunables, so the default collection is used; the field is
  /// named to document the deliberate libsecret backing and give a single place
  /// to tighten options if a future plugin version adds them.
  static const LinuxOptions _linuxOptions = LinuxOptions();

  static FlutterSecureStorage _defaultStorage() =>
      const FlutterSecureStorage(lOptions: _linuxOptions);

  @override
  Future<String?> read(String key) async {
    try {
      // A reachable store with no value returns null; that null flows through
      // unchanged as a legitimate "no key yet" answer.
      return await _storage.read(key: key, lOptions: _linuxOptions);
    } on Object catch (error, stackTrace) {
      // Any plugin/keyring failure is an OUTAGE, never "absent". Fail closed to
      // unavailable so the vault/composition root never mistakes it for a fresh
      // install (R-SEC-001).
      throw SecureKeyStoreUnavailable(
        'Secure storage read failed for "$key": $error',
        _CauseWithStack(error, stackTrace),
      );
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value, lOptions: _linuxOptions);
    } on Object catch (error, stackTrace) {
      throw SecureKeyStoreUnavailable(
        'Secure storage write failed for "$key": $error',
        _CauseWithStack(error, stackTrace),
      );
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key, lOptions: _linuxOptions);
    } on Object catch (error, stackTrace) {
      throw SecureKeyStoreUnavailable(
        'Secure storage delete failed for "$key": $error',
        _CauseWithStack(error, stackTrace),
      );
    }
  }
}

/// Carries the original error and its stack trace as the [Exception] cause so
/// diagnostics retain the underlying plugin failure without the adapter needing
/// to know the concrete exception type.
final class _CauseWithStack {
  const _CauseWithStack(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;

  @override
  String toString() => '$error\n$stackTrace';
}
