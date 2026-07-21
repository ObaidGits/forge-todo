/// A redacting wrapper for auth secrets (access/refresh tokens, authorization
/// codes, state, and nonce values) so they never leak through logs, `toString`,
/// diagnostics, or error messages (R-SEC-004, design.md §13).
///
/// The value compares by content — verification (state/nonce equality) needs
/// that — but every string rendering is `[redacted]`. Callers must go through
/// [reveal] to obtain the raw value, which is only ever handed to the transport
/// boundary or secure storage.
library;

final class SecretString {
  const SecretString(this._value);

  final String _value;

  bool get isEmpty => _value.isEmpty;

  int get length => _value.length;

  /// Returns the underlying secret. Use only at the transport/storage boundary.
  String reveal() => _value;

  @override
  bool operator ==(Object other) =>
      other is SecretString && other._value == _value;

  @override
  int get hashCode => _value.hashCode;

  @override
  String toString() => '[redacted]';
}
