import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/notes/domain/markdown/markdown_node.dart';
import 'package:forge/features/notes/domain/markdown/safe_markdown.dart';
import 'package:forge/features/notes/domain/markdown/safe_url.dart';
import 'package:forge/features/notes/domain/markdown/wiki_link.dart';

/// The safe Markdown parser neutralizes every dangerous construct and preserves
/// the supported ones (R-NOTE-001). The full editor/preview UI is task 5.3;
/// these tests exercise the sanitizing domain logic that produces the AST.
///
/// **Validates: Requirements R-NOTE-001, R-NOTE-004, R-SEC-005**
void main() {
  group('raw HTML neutralization (R-NOTE-001)', () {
    test('a <script> block never survives as markup', () {
      const String body = 'before <script>alert(1)</script> after';
      final String html = SafeMarkdown.parse(body).toSafeHtml();
      expect(html, isNot(contains('<script>')));
      expect(html, contains('&lt;script&gt;'));
      // The literal text is preserved (escaped) for display.
      expect(html, contains('alert(1)'));
    });

    test('inline event-handler HTML is escaped, not interpreted', () {
      const String body = '<img src=x onerror=alert(1)>';
      final String html = SafeMarkdown.parse(body).toSafeHtml();
      expect(html, isNot(contains('<img')));
      expect(html, contains('&lt;img'));
      expect(html, isNot(contains('onerror=alert(1)>')));
    });

    test('HTML inside a code span stays literal', () {
      final String html = SafeMarkdown.parse('`<b>x</b>`').toSafeHtml();
      expect(html, contains('<code>&lt;b&gt;x&lt;/b&gt;</code>'));
    });
  });

  group('unsafe link neutralization (R-NOTE-001, R-SEC-005)', () {
    test('a javascript: link renders as plain label, no href', () {
      final String html = SafeMarkdown.parse(
        '[click](javascript:alert(1))',
      ).toSafeHtml();
      expect(html, isNot(contains('javascript:')));
      expect(html, isNot(contains('href')));
      expect(html, contains('click'));
    });

    test('a data: link is neutralized', () {
      final String html = SafeMarkdown.parse(
        '[x](data:text/html;base64,PHNjcmlwdD4=)',
      ).toSafeHtml();
      expect(html, isNot(contains('data:')));
      expect(html, isNot(contains('href')));
    });

    test('whitespace/control obfuscated scheme is still rejected', () {
      final String html = SafeMarkdown.parse(
        '[x](java\tscript:alert(1))',
      ).toSafeHtml();
      expect(html.toLowerCase(), isNot(contains('script:')));
      expect(html, isNot(contains('href')));
    });

    test('a safe https link is kept with an escaped href', () {
      final String html = SafeMarkdown.parse(
        '[docs](https://example.com/a?b=c)',
      ).toSafeHtml();
      expect(html, contains('<a href="https://example.com/a?b=c">docs</a>'));
    });

    test('a mailto link is kept', () {
      final String html = SafeMarkdown.parse(
        '[mail](mailto:a@b.com)',
      ).toSafeHtml();
      expect(html, contains('href="mailto:a@b.com"'));
    });
  });

  group('SafeUrl policy', () {
    test('allows http/https/mailto/tel and relative refs', () {
      expect(SafeUrl.isSafe('https://x.com'), isTrue);
      expect(SafeUrl.isSafe('http://x.com'), isTrue);
      expect(SafeUrl.isSafe('mailto:a@b.com'), isTrue);
      expect(SafeUrl.isSafe('tel:+123'), isTrue);
      expect(SafeUrl.isSafe('/relative/path'), isTrue);
      expect(SafeUrl.isSafe('relative'), isTrue);
    });

    test('rejects dangerous and protocol-relative schemes', () {
      expect(SafeUrl.isSafe('javascript:alert(1)'), isFalse);
      expect(SafeUrl.isSafe('JavaScript:alert(1)'), isFalse);
      expect(SafeUrl.isSafe('data:text/html,x'), isFalse);
      expect(SafeUrl.isSafe('vbscript:x'), isFalse);
      expect(SafeUrl.isSafe('file:///etc/passwd'), isFalse);
      expect(SafeUrl.isSafe('//evil.example.com'), isFalse);
      expect(SafeUrl.isSafe(''), isFalse);
    });

    test('sanitize returns empty for unsafe and the target for safe', () {
      expect(SafeUrl.sanitize('javascript:x'), isEmpty);
      expect(SafeUrl.sanitize('  https://x.com '), 'https://x.com');
    });
  });

  group('supported constructs (R-NOTE-001)', () {
    test('headings, emphasis, strong and inline code parse', () {
      final MarkdownDocument doc = SafeMarkdown.parse(
        '# Title\n\nSome **bold** and *italic* and `code`.',
      );
      expect(doc.blocks.first, isA<MarkdownHeading>());
      final String html = doc.toSafeHtml();
      expect(html, contains('<h1>Title</h1>'));
      expect(html, contains('<strong>bold</strong>'));
      expect(html, contains('<em>italic</em>'));
      expect(html, contains('<code>code</code>'));
    });

    test('task checkboxes parse with checked state', () {
      final MarkdownDocument doc = SafeMarkdown.parse('- [ ] todo\n- [x] done');
      final MarkdownList list = doc.blocks.single as MarkdownList;
      expect(list.items, hasLength(2));
      expect(list.items[0].checkbox, isFalse);
      expect(list.items[1].checkbox, isTrue);
    });

    test('fenced code blocks keep literal content', () {
      final MarkdownDocument doc = SafeMarkdown.parse(
        '```dart\nvar x = "<b>";\n```',
      );
      final MarkdownCodeBlock code = doc.blocks.single as MarkdownCodeBlock;
      expect(code.language, 'dart');
      expect(code.text, 'var x = "<b>";');
      expect(doc.toSafeHtml(), contains('&lt;b&gt;'));
    });

    test('safe autolink becomes a link; unsafe autolink stays literal', () {
      expect(
        SafeMarkdown.parse('<https://x.com>').toSafeHtml(),
        contains('href="https://x.com"'),
      );
      final String unsafe = SafeMarkdown.parse(
        '<javascript:alert(1)>',
      ).toSafeHtml();
      expect(unsafe, isNot(contains('href')));
      expect(unsafe, contains('&lt;javascript'));
    });
  });

  group('plain-text extraction for search (R-NOTE-004)', () {
    test('markup is stripped to searchable prose', () {
      final String text = SafeMarkdown.parse(
        '# Heading\n\nA **bold** [link](https://x.com) and `code()`.',
      ).toPlainText();
      expect(text, contains('Heading'));
      expect(text, contains('bold'));
      expect(text, contains('link'));
      expect(text, contains('code()'));
      expect(text, isNot(contains('**')));
      expect(text, isNot(contains('](')));
    });
  });

  group('wiki-link extraction (R-NOTE-003)', () {
    test('extracts targets and aliases with positions', () {
      const String body = 'See [[Alpha]] and [[Beta|the beta]].';
      final List<WikiLinkRef> refs = WikiLink.extract(body);
      expect(refs, hasLength(2));
      expect(refs[0].target, 'Alpha');
      expect(refs[0].label, 'Alpha');
      expect(refs[1].target, 'Beta');
      expect(refs[1].label, 'the beta');
      // Positions are exact source ranges.
      expect(body.substring(refs[0].start, refs[0].end), '[[Alpha]]');
    });

    test('ignores wiki-links inside code', () {
      final List<WikiLinkRef> refs = WikiLink.extract(
        '`[[NotALink]]` [[Real]]',
      );
      expect(refs.map((WikiLinkRef r) => r.target), <String>['Real']);
    });

    test('skips empty targets', () {
      expect(WikiLink.extract('[[]] [[ | x ]]'), isEmpty);
    });

    test('the parser produces safe internal wiki-link spans', () {
      final String html = SafeMarkdown.parse('go to [[My Note]]').toSafeHtml();
      expect(html, contains('data-wikilink="My Note"'));
      expect(html, isNot(contains('href')));
    });
  });
}
