/// Safe FTS5 query construction (R-SEARCH-002 "highlight safely, support
/// filters"; R-SEC hardening).
///
/// User-entered search text is untrusted: it may contain FTS5 operators
/// (`"`, `*`, `:`, `^`, `-`, `(`, `)`, `AND`, `OR`, `NOT`, `NEAR`) or malformed
/// fragments that would either raise a syntax error or reach unintended index
/// behavior. [SearchQuerySanitizer] converts free text into a MATCH expression
/// that can never be broken out of: every token is emitted as a quoted FTS5
/// string, which the tokenizer treats as literal text, and tokens are combined
/// with implicit AND. An optional trailing prefix match supports as-you-type
/// search without exposing the `*` operator to the user.
library;

/// Converts untrusted free text into a safe FTS5 MATCH expression.
abstract final class SearchQuerySanitizer {
  /// Characters FTS5's default tokenizer treats as token separators are not
  /// meaningful inside a quoted string; we only need to split the user text
  /// into word-ish tokens and quote each one. A "token" here is any maximal run
  /// of characters that is not whitespace and not a bare FTS5 operator glyph.
  static final RegExp _separators = RegExp(r'[\s"*():^\-]+');

  /// Builds a safe MATCH expression from [rawQuery].
  ///
  /// Returns `null` when the query has no searchable tokens (e.g. empty, only
  /// whitespace, or only operator punctuation), signalling the caller to return
  /// no results rather than issue a degenerate MATCH. When [prefix] is true the
  /// final token is turned into a prefix match (`"tok"*`) for as-you-type use.
  static String? toMatchExpression(String rawQuery, {bool prefix = false}) {
    final List<String> tokens = _tokenize(rawQuery);
    if (tokens.isEmpty) {
      return null;
    }
    final List<String> quoted = <String>[];
    for (int i = 0; i < tokens.length; i++) {
      final bool isLast = i == tokens.length - 1;
      final String literal = _quote(tokens[i]);
      quoted.add(prefix && isLast ? '$literal *' : literal);
    }
    return quoted.join(' AND ');
  }

  /// Splits [rawQuery] into literal tokens, dropping empty fragments. Every FTS5
  /// operator glyph is a separator, so no operator can survive tokenization.
  static List<String> _tokenize(String rawQuery) => rawQuery
      .split(_separators)
      .where((String t) => t.isNotEmpty)
      .toList(growable: false);

  /// Wraps [token] as an FTS5 string literal, doubling embedded double quotes.
  /// Because the token was split on `"` already this is defensive, but it keeps
  /// the function correct for any input passed directly.
  static String _quote(String token) {
    final String escaped = token.replaceAll('"', '""');
    return '"$escaped"';
  }
}
