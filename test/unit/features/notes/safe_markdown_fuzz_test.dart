import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/notes/domain/markdown/markdown_node.dart';
import 'package:forge/features/notes/domain/markdown/safe_markdown.dart';
import 'package:forge/features/notes/domain/markdown/safe_url.dart';
import 'package:forge/features/notes/domain/markdown/wiki_link.dart';

/// Generative (fuzz) property tests for the safe Markdown renderer.
///
/// Where [safe_markdown_test.dart] pins specific adversarial examples, this
/// suite proves the sanitizer holds across a large space of randomly assembled
/// documents built from a palette that mixes benign Markdown with the usual
/// XSS/raw-HTML/unsafe-link attack tokens. For every generated body the
/// invariants are:
///
///   1. Parsing and every projection ([toSafeHtml], [toPlainText],
///      [WikiLink.extract]) never throw, at any nesting/size.
///   2. The rendered HTML contains only the closed set of tags the AST emits —
///      no raw HTML element (`<script>`, `<img>`, `<iframe>`, `<svg>`, …) can
///      ever survive as markup; anything else is HTML-escaped literal text.
///   3. No inline event-handler attribute (`onerror=`, `onclick=`, …) appears.
///   4. Every emitted `href` is a [SafeUrl]-safe target — a `javascript:`,
///      `data:`, `vbscript:` or `file:` scheme can never become navigable.
///
/// **Validates: Requirements R-NOTE-001, R-SEC-005**
void main() {
  // The complete set of tags the safe AST is allowed to emit (see
  // markdown_node.dart). Anything outside this set would be raw HTML that
  // leaked through sanitization.
  const Set<String> allowedTags = <String>{
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'p',
    'pre',
    'code',
    'blockquote',
    'ol',
    'ul',
    'li',
    'hr',
    'strong',
    'em',
    'a',
    'input',
  };

  // Adversarial and benign source fragments the generator samples from.
  const List<String> tokens = <String>[
    // Raw-HTML / script injection attempts.
    '<script>alert(1)</script>',
    '<SCRIPT>alert(1)</SCRIPT>',
    '<img src=x onerror=alert(1)>',
    '<iframe src="javascript:alert(1)">',
    '<svg onload=alert(1)>',
    '<style>*{}</style>',
    '<a href="javascript:alert(1)">x</a>',
    '<object data="x"></object>',
    '<body onload=alert(1)>',
    '</p></div><b>',
    // Unsafe link targets in Markdown and autolink forms.
    '[click](javascript:alert(1))',
    '[x](data:text/html;base64,PHNjcmlwdD4=)',
    '[y](vbscript:msgbox(1))',
    '[z](file:///etc/passwd)',
    '[w](java\tscript:alert(1))',
    '[p](//evil.example.com)',
    '<javascript:alert(1)>',
    '<data:text/html,x>',
    // Safe constructs that must be preserved.
    '[docs](https://example.com/a?b=c)',
    '[mail](mailto:a@b.com)',
    '<https://ok.example.com>',
    '# Heading',
    '## Sub heading',
    '**bold**',
    '*italic*',
    '`code <b>span</b>`',
    '```dart\nvar x = "<script>";\n```',
    '- [ ] todo item',
    '- [x] done item',
    '1. first',
    '> quoted <script>',
    '[[Wiki Target]]',
    '[[Target|alias <b>]]',
    '---',
    // Nasty structural / unicode / control fragments.
    '[[[[[[unbalanced',
    '](()(](',
    r'\<not a tag\>',
    '<<<>>>',
    '&amp;&lt;&gt;',
    '"\'"\'quotes',
    'ünïcödé \u202e rtl',
    '\u0000\u0001\u0007 controls',
    '     ',
    '\t\t\ttabs',
  ];

  String randomBody(Random random) {
    final int lineCount = random.nextInt(14);
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < lineCount; i += 1) {
      final int fragments = 1 + random.nextInt(4);
      for (int f = 0; f < fragments; f += 1) {
        buffer.write(tokens[random.nextInt(tokens.length)]);
        if (random.nextBool()) {
          buffer.write(' ');
        }
      }
      buffer.write('\n');
    }
    return buffer.toString();
  }

  /// Extracts the lowercased tag names present in [html].
  Iterable<String> tagsIn(String html) => RegExp(
    r'<\/?([a-zA-Z][a-zA-Z0-9]*)',
  ).allMatches(html).map((Match m) => m.group(1)!.toLowerCase());

  /// Extracts and HTML-unescapes every `href` value that appears in a *real*
  /// emitted tag. Escaped literal text renders angle brackets as `&lt;`/`&gt;`,
  /// so `RegExp('<[^>]*>')` isolates only genuine markup: a `href="…"` string
  /// buried in escaped literal text is inert and correctly ignored here.
  Iterable<String> hrefsIn(String html) sync* {
    for (final Match tag in RegExp('<[^>]*>').allMatches(html)) {
      final Match? href = RegExp('href="([^"]*)"').firstMatch(tag.group(0)!);
      if (href != null) {
        yield href
            .group(1)!
            .replaceAll('&quot;', '"')
            .replaceAll('&#39;', "'")
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&amp;', '&');
      }
    }
  }

  for (final int seed in <int>[1, 7, 42, 1337, 99999]) {
    test(
      '[TEST-NOTE-MD-FUZZ-001][MVP][TASK-5.6][R-NOTE-001,R-SEC-005] '
      'random adversarial Markdown never emits unsafe markup (seed=$seed)',
      () {
        final Random random = Random(seed);
        for (int iteration = 0; iteration < 400; iteration += 1) {
          final String body = randomBody(random);

          // (1) No projection throws, regardless of the input.
          late final MarkdownDocument doc;
          expect(() => doc = SafeMarkdown.parse(body), returnsNormally);
          late final String html;
          expect(() => html = doc.toSafeHtml(), returnsNormally);
          expect(doc.toPlainText, returnsNormally);
          expect(() => WikiLink.extract(body), returnsNormally);

          final String lower = html.toLowerCase();

          // (2) Only the closed set of AST tags is present.
          for (final String tag in tagsIn(html)) {
            expect(
              allowedTags,
              contains(tag),
              reason: 'raw HTML tag <$tag> leaked for body: $body',
            );
          }
          // A defused script/iframe can never appear as markup.
          expect(lower, isNot(contains('<script')));
          expect(lower, isNot(contains('<iframe')));
          expect(lower, isNot(contains('<img')));
          expect(lower, isNot(contains('<svg')));

          // (3) No emitted tag carries an inline event-handler *attribute*.
          // Only real `<...>` tags are inspected (escaped literal text renders
          // as `&lt;...&gt;` and is inert). Quoted attribute values are removed
          // first, so an `onerror=` string that lives inside the escaped value
          // of a legitimate data attribute (e.g. `data-wikilink="…&lt;img
          // onerror=…&gt;"`) is correctly treated as inert content, not markup.
          for (final Match tag in RegExp('<[^>]*>').allMatches(lower)) {
            final String attrs = tag
                .group(0)!
                .replaceAll(RegExp('"[^"]*"'), '""');
            expect(
              RegExp(r'\son[a-z]+\s*=').hasMatch(attrs),
              isFalse,
              reason: 'event-handler attribute leaked for body: $body',
            );
          }

          // (4) Every navigable href is a SafeUrl-safe target.
          for (final String href in hrefsIn(html)) {
            expect(
              SafeUrl.isSafe(href),
              isTrue,
              reason: 'unsafe href "$href" emitted for body: $body',
            );
          }
        }
      },
    );
  }

  test(
    '[TEST-NOTE-MD-FUZZ-DEEP][MVP][TASK-5.6][R-NOTE-001] '
    'deeply nested emphasis and brackets terminate without stack overflow',
    () {
      final String nestedEmphasis = '${'*' * 500}x${'*' * 500}';
      final String nestedBrackets = '${'[' * 500}x${']' * 500}';
      final String nestedQuotes = '${'> ' * 200}payload <script>';
      for (final String body in <String>[
        nestedEmphasis,
        nestedBrackets,
        nestedQuotes,
      ]) {
        expect(() => SafeMarkdown.parse(body).toSafeHtml(), returnsNormally);
        expect(
          SafeMarkdown.parse(body).toSafeHtml().toLowerCase(),
          isNot(contains('<script')),
        );
      }
    },
  );
}
