import 'package:forge/core/security/secure_key_store.dart';

/// Deterministic in-memory [SecureKeyStore] for tests.
///
/// It faithfully models the port's critical distinction between a reachable
/// store that simply has no value (returns `null`) and an UNAVAILABLE secret
/// service (throws [SecureKeyStoreUnavailable]). Toggle [available] to simulate
/// a keyring outage, and inspect [writes] to assert the vault never persists a
/// replacement key when it must not.
final class FakeSecureKeyStore implements SecureKeyStore {
  FakeSecureKeyStore({Map<String, String>? seed, this.available = true})
    : _values = <String, String>{...?seed};

  final Map<String, String> _values;

  /// When false, every operation throws [SecureKeyStoreUnavailable], modeling a
  /// missing keyring daemon / locked keychain / denied entitlement.
  bool available;

  /// Count of successful [write] calls — used to prove no replacement key is
  /// minted when ciphertext already exists.
  int writeCount = 0;

  /// Count of [read] calls.
  int readCount = 0;

  String? valueFor(String key) => _values[key];

  bool contains(String key) => _values.containsKey(key);

  @override
  Future<String?> read(String key) async {
    readCount += 1;
    if (!available) {
      throw const SecureKeyStoreUnavailable('store offline (test)');
    }
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (!available) {
      throw const SecureKeyStoreUnavailable('store offline (test)');
    }
    writeCount += 1;
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (!available) {
      throw const SecureKeyStoreUnavailable('store offline (test)');
    }
    _values.remove(key);
  }
}
