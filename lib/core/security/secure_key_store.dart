/// A minimal, async port over an OS-backed secret store (libsecret on Linux,
/// Keychain on Apple platforms, DPAPI on Windows, Keystore on Android).
///
/// ## Why a port instead of the plugin directly
/// The device-key custodian ([SecureStorageKeyVault]) is a security-critical,
/// invariant-preserving component. Binding it to a concrete plugin would make
/// it impossible to unit-test the R-SEC-001 no-replacement-key logic without a
/// live OS keyring, and would couple the vault to a build-time native link
/// (libsecret). Instead the vault depends only on this pure-Dart port; tests
/// inject an in-memory fake, and a thin production adapter over an OS
/// secret-storage plugin (e.g. `flutter_secure_storage`) implements this port
/// on a target where that plugin's native library can be linked.
///
/// NOTE: no production adapter is wired in this build. The current target
/// cannot link `libsecret` (no `libsecret-1-dev`), so the plugin dependency was
/// intentionally left out and the composition root wires [LocalFileKeyVault].
/// Adding an adapter that implements this port is the only change required to
/// activate [SecureStorageKeyVault] on a secret-service-enabled target.
///
/// ## Availability vs. absence — the critical distinction (R-SEC-001)
/// Implementations MUST distinguish two very different outcomes on [read]:
///   * The store is reachable and simply has no value for the key — return
///     `null`. This is a legitimate "no key yet" answer.
///   * The store itself is UNAVAILABLE at runtime (no keyring daemon on a
///     headless box, a locked/absent keychain, a denied entitlement, or a
///     missing platform plugin) — throw [SecureKeyStoreUnavailable].
/// Collapsing "unavailable" into "absent" would let a transient keyring outage
/// masquerade as a fresh install and risk minting a replacement key over
/// existing ciphertext. The vault relies on this distinction to fail closed.
library;

/// Thrown when the underlying OS secret service cannot be reached or operated
/// at runtime. It signals the composition root to fall back to a local vault;
/// it does NOT mean any key was lost or that the install is fresh.
final class SecureKeyStoreUnavailable implements Exception {
  const SecureKeyStoreUnavailable(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'SecureKeyStoreUnavailable($message${cause == null ? '' : ', $cause'})';
}

/// Async key/value access to an OS secret store. Values are opaque strings so
/// the concrete plugin contract (which stores strings) is honored; the vault is
/// responsible for encoding/decoding raw key bytes.
abstract interface class SecureKeyStore {
  /// Returns the stored value for [key], or `null` when the store is reachable
  /// but holds no value. Throws [SecureKeyStoreUnavailable] when the secret
  /// service itself cannot be reached.
  Future<String?> read(String key);

  /// Persists [value] under [key]. Throws [SecureKeyStoreUnavailable] when the
  /// secret service cannot be reached/written.
  Future<void> write(String key, String value);

  /// Removes any value stored under [key]. Throws [SecureKeyStoreUnavailable]
  /// when the secret service cannot be reached.
  Future<void> delete(String key);
}
