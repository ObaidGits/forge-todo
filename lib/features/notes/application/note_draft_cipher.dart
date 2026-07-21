/// Synchronous authenticated cipher for the encrypted draft journal
/// (R-NOTE-005).
///
/// The draft body is encrypted at rest so a durable, restart-safe recovery copy
/// exists without ever writing note content to OS restoration data. Encryption
/// runs inside the write transaction, so it MUST be synchronous and free of
/// plugin/isolate calls (design.md §5 forbids plugin calls inside a database
/// transaction). Production wiring supplies an adapter over key material
/// released by the [KeyVault] (an AEAD over the profile key); tests supply a
/// deterministic reversible fake. The port keeps the notes feature free of any
/// concrete crypto dependency.
abstract interface class NoteDraftCipher {
  /// Encrypts [plaintext] into an opaque, storable envelope.
  String seal(String plaintext);

  /// Decrypts an envelope produced by [seal]. Throws when the envelope is not
  /// authentic.
  String open(String sealed);
}
