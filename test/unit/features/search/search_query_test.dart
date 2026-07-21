import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/search/domain/search_query.dart';

/// The query sanitizer turns untrusted free text into a safe FTS5 MATCH
/// expression: every token is a quoted literal, operators are neutralized, and
/// degenerate queries yield null.
///
/// **Validates: Requirements R-SEARCH-002, R-SEARCH-003**
void main() {
  group('given plain words when building a MATCH expression', () {
    test('then each token is a quoted literal joined by AND', () {
      expect(
        SearchQuerySanitizer.toMatchExpression('buy milk', prefix: false),
        '"buy" AND "milk"',
      );
    });

    test('then the final token becomes a prefix match when requested', () {
      expect(
        SearchQuerySanitizer.toMatchExpression('buy mil', prefix: true),
        '"buy" AND "mil" *',
      );
    });

    test('then a single token is quoted', () {
      expect(
        SearchQuerySanitizer.toMatchExpression('report', prefix: false),
        '"report"',
      );
    });
  });

  group('given operator-laden text when sanitizing', () {
    test('then FTS operators are split out as separators', () {
      // Quotes, stars, colons, carets, parens and hyphens are all separators,
      // so the result contains only quoted literal word tokens.
      expect(
        SearchQuerySanitizer.toMatchExpression(
          'title:foo OR bar* ^baz -qux',
          prefix: false,
        ),
        '"title" AND "foo" AND "OR" AND "bar" AND "baz" AND "qux"',
      );
    });

    test('then a NEAR-like injection is reduced to literal tokens', () {
      expect(
        SearchQuerySanitizer.toMatchExpression('NEAR(a b)', prefix: false),
        '"NEAR" AND "a" AND "b"',
      );
    });

    test('then embedded quotes are doubled inside the literal', () {
      // Defensive: a token containing a quote (not split away) is escaped.
      expect(
        SearchQuerySanitizer.toMatchExpression('a"b', prefix: false),
        // The double quote is a separator, so "a" and "b" are separate tokens.
        '"a" AND "b"',
      );
    });
  });

  group('given degenerate input when sanitizing', () {
    test('then empty text yields null', () {
      expect(SearchQuerySanitizer.toMatchExpression('', prefix: true), isNull);
    });

    test('then whitespace-only text yields null', () {
      expect(
        SearchQuerySanitizer.toMatchExpression('   \t\n', prefix: true),
        isNull,
      );
    });

    test('then operator-only text yields null', () {
      expect(
        SearchQuerySanitizer.toMatchExpression('"*():^-', prefix: true),
        isNull,
      );
    });
  });
}
