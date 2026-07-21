/// Link-target safety policy for note Markdown (R-NOTE-001 "unsafe links",
/// R-SEC-005).
///
/// A note body is untrusted user content that may be shared through backup or
/// (later) sync, so link targets are validated before they can ever become a
/// navigable href. The policy is scheme-allowlist based: only well-known
/// navigable schemes are permitted, everything else (notably `javascript:`,
/// `data:`, `vbscript:`, `file:`) is neutralized. Scheme detection is performed
/// after stripping ASCII control characters and whitespace, which are the usual
/// obfuscation vectors (e.g. `java\tscript:` or `java\nscript:`).
abstract final class SafeUrl {
  /// Navigable schemes allowed in rendered note links.
  static const Set<String> allowedSchemes = <String>{
    'http',
    'https',
    'mailto',
    'tel',
  };

  /// Whether [raw] may be rendered as a navigable href.
  ///
  /// A scheme-relative or relative reference (no scheme before the first path
  /// separator) is treated as internal and allowed. A URL whose scheme is not
  /// in [allowedSchemes] is rejected.
  static bool isSafe(String raw) {
    final String cleaned = _stripObfuscation(raw);
    if (cleaned.isEmpty) {
      return false;
    }
    // Protocol-relative `//host` references reach the network without a scheme;
    // treat them as unsafe so they cannot smuggle an external target.
    if (cleaned.startsWith('//')) {
      return false;
    }
    final Match? scheme = _scheme.firstMatch(cleaned);
    if (scheme == null) {
      // No scheme: a relative/internal reference. Allowed.
      return true;
    }
    return allowedSchemes.contains(scheme.group(1)!.toLowerCase());
  }

  /// Returns the sanitized href for [raw] when safe, or an empty string when it
  /// must be neutralized. The returned value trims surrounding whitespace but
  /// preserves the target otherwise.
  static String sanitize(String raw) {
    final String trimmed = raw.trim();
    return isSafe(trimmed) ? trimmed : '';
  }

  static String _stripObfuscation(String value) =>
      value.replaceAll(_controlAndSpace, '');

  static final RegExp _controlAndSpace = RegExp(r'[\u0000-\u0020\u007f]');
  static final RegExp _scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.\-]*):');
}
