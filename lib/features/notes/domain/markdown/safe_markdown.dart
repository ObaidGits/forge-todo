import 'package:forge/features/notes/domain/markdown/markdown_node.dart';
import 'package:forge/features/notes/domain/markdown/safe_url.dart';

/// A focused, security-first Markdown parser (R-NOTE-001).
///
/// It supports the constructs the notes feature commits to — headings,
/// paragraphs, emphasis/strong, inline and fenced code, links, `[[wiki-links]]`,
/// blockquotes, ordered/unordered lists and task checkboxes, and thematic
/// breaks — and, crucially, neutralizes everything dangerous:
///
///  * Raw HTML is never interpreted as markup. Any `<...>` that is not a safe
///    autolink is carried as literal [MarkdownText], which the AST HTML-escapes
///    on render, so `<script>…</script>` can never execute.
///  * Link and autolink targets are validated by [SafeUrl]; a disallowed scheme
///    (`javascript:`, `data:`, `vbscript:`, `file:`, …) yields a neutralized
///    link that renders as plain label text with no navigable target.
///  * Code content is always literal and never re-parsed as Markdown or HTML.
///
/// This is pure domain logic (no Flutter/plugin imports); the editor/preview UI
/// that renders the resulting [MarkdownDocument] lands in task 5.3.
abstract final class SafeMarkdown {
  /// Parses [source] into a neutralized [MarkdownDocument].
  static MarkdownDocument parse(String source) {
    final List<String> lines = _normalize(source).split('\n');
    final List<MarkdownBlock> blocks = _parseBlocks(lines);
    return MarkdownDocument(blocks);
  }

  // ---- block level --------------------------------------------------------

  static List<MarkdownBlock> _parseBlocks(List<String> lines) {
    final List<MarkdownBlock> blocks = <MarkdownBlock>[];
    int i = 0;
    while (i < lines.length) {
      final String line = lines[i];

      if (line.trim().isEmpty) {
        i += 1;
        continue;
      }

      // Fenced code block.
      final Match? fence = _fence.firstMatch(line);
      if (fence != null) {
        final String language = fence.group(2)!.trim();
        final List<String> body = <String>[];
        i += 1;
        while (i < lines.length && _fence.firstMatch(lines[i]) == null) {
          body.add(lines[i]);
          i += 1;
        }
        if (i < lines.length) {
          i += 1; // consume the closing fence
        }
        blocks.add(
          MarkdownCodeBlock(
            text: body.join('\n'),
            language: language.isEmpty ? null : language,
          ),
        );
        continue;
      }

      // Thematic break.
      if (_thematicBreak.hasMatch(line)) {
        blocks.add(const MarkdownThematicBreak());
        i += 1;
        continue;
      }

      // ATX heading.
      final Match? heading = _heading.firstMatch(line);
      if (heading != null) {
        final int level = heading.group(1)!.length;
        blocks.add(
          MarkdownHeading(
            level: level,
            inlines: _parseInlines(heading.group(2)!.trim()),
          ),
        );
        i += 1;
        continue;
      }

      // Blockquote: consume the contiguous run of `>` lines.
      if (line.trimLeft().startsWith('>')) {
        final List<String> quoted = <String>[];
        while (i < lines.length && lines[i].trimLeft().startsWith('>')) {
          quoted.add(lines[i].trimLeft().replaceFirst(RegExp(r'^>\s?'), ''));
          i += 1;
        }
        blocks.add(MarkdownBlockQuote(_parseBlocks(quoted)));
        continue;
      }

      // List (ordered or unordered), possibly with task checkboxes.
      if (_unordered.hasMatch(line) || _ordered.hasMatch(line)) {
        final bool ordered = _ordered.hasMatch(line);
        final List<MarkdownListItem> items = <MarkdownListItem>[];
        while (i < lines.length) {
          final String current = lines[i];
          final Match? m = ordered
              ? _ordered.firstMatch(current)
              : _unordered.firstMatch(current);
          if (m == null) {
            if (current.trim().isEmpty) {
              break;
            }
            break;
          }
          String content = m.group(m.groupCount)!;
          bool? checkbox;
          final Match? task = _taskBox.firstMatch(content);
          if (task != null) {
            final String mark = task.group(1)!.toLowerCase();
            checkbox = mark == 'x';
            content = content.substring(task.end);
          }
          items.add(
            MarkdownListItem(
              inlines: _parseInlines(content.trim()),
              checkbox: checkbox,
            ),
          );
          i += 1;
        }
        blocks.add(MarkdownList(ordered: ordered, items: items));
        continue;
      }

      // Paragraph: gather consecutive "plain" lines.
      final List<String> paragraph = <String>[];
      while (i < lines.length && _isParagraphLine(lines[i])) {
        paragraph.add(lines[i].trim());
        i += 1;
      }
      blocks.add(MarkdownParagraph(_parseInlines(paragraph.join(' '))));
    }
    return blocks;
  }

  static bool _isParagraphLine(String line) {
    if (line.trim().isEmpty) {
      return false;
    }
    if (_fence.hasMatch(line) ||
        _thematicBreak.hasMatch(line) ||
        _heading.hasMatch(line) ||
        _unordered.hasMatch(line) ||
        _ordered.hasMatch(line) ||
        line.trimLeft().startsWith('>')) {
      return false;
    }
    return true;
  }

  // ---- inline level -------------------------------------------------------

  /// Parses inline content, neutralizing raw HTML and unsafe links.
  static List<MarkdownInline> _parseInlines(String text) {
    final List<MarkdownInline> out = <MarkdownInline>[];
    final StringBuffer buffer = StringBuffer();

    void flush() {
      if (buffer.isNotEmpty) {
        out.add(MarkdownText(buffer.toString()));
        buffer.clear();
      }
    }

    int i = 0;
    final int n = text.length;
    while (i < n) {
      final String c = text[i];

      // Backslash escape of ASCII punctuation.
      if (c == r'\' && i + 1 < n && _isPunctuation(text[i + 1])) {
        buffer.write(text[i + 1]);
        i += 2;
        continue;
      }

      // Inline code span (literal content).
      if (c == '`') {
        final int runEnd = _matchRun(text, i, '`');
        final int close = text.indexOf(text.substring(i, runEnd), runEnd);
        if (close != -1) {
          flush();
          out.add(MarkdownCodeSpan(text.substring(runEnd, close)));
          i = close + (runEnd - i);
          continue;
        }
      }

      // Wiki-link `[[target]]` / `[[target|label]]`.
      if (c == '[' && i + 1 < n && text[i + 1] == '[') {
        final int close = text.indexOf(']]', i + 2);
        if (close != -1) {
          final String inner = text.substring(i + 2, close);
          final int pipe = inner.indexOf('|');
          final String target = (pipe < 0 ? inner : inner.substring(0, pipe))
              .trim();
          if (target.isNotEmpty) {
            final String label = pipe < 0
                ? target
                : inner.substring(pipe + 1).trim();
            flush();
            out.add(
              MarkdownWikiLink(
                target: target,
                label: label.isEmpty ? target : label,
              ),
            );
            i = close + 2;
            continue;
          }
        }
      }

      // Inline link `[label](url)`.
      if (c == '[') {
        final _LinkMatch? link = _matchLink(text, i);
        if (link != null) {
          flush();
          final String href = SafeUrl.sanitize(link.url);
          out.add(
            MarkdownLink(
              children: _parseInlines(link.label),
              href: href,
              safe: href.isNotEmpty,
            ),
          );
          i = link.end;
          continue;
        }
      }

      // Autolink `<scheme:...>` — only safe schemes become links; otherwise the
      // `<` is literal text (raw HTML is never interpreted). Matched with
      // [Pattern.matchAsPrefix] anchored at [i] so a `<`-dense body cannot force
      // a per-character tail copy (which would make inline parsing O(n²) and
      // could stall the UI thread on a large note; NFR-PERF budgets).
      if (c == '<') {
        final Match? auto = _autolink.matchAsPrefix(text, i);
        if (auto != null) {
          final String url = auto.group(1)!;
          if (SafeUrl.isSafe(url)) {
            flush();
            out.add(
              MarkdownLink(
                children: <MarkdownInline>[MarkdownText(url)],
                href: url,
                safe: true,
              ),
            );
            i = auto.end;
            continue;
          }
        }
      }

      // Strong emphasis (`**` / `__`).
      if ((c == '*' || c == '_') && i + 1 < n && text[i + 1] == c) {
        final String delim = c + c;
        final int close = text.indexOf(delim, i + 2);
        if (close != -1 && close > i + 2) {
          flush();
          out.add(
            MarkdownEmphasis(
              strong: true,
              children: _parseInlines(text.substring(i + 2, close)),
            ),
          );
          i = close + 2;
          continue;
        }
      }

      // Emphasis (`*` / `_`).
      if (c == '*' || c == '_') {
        final int close = text.indexOf(c, i + 1);
        if (close != -1 && close > i + 1) {
          flush();
          out.add(
            MarkdownEmphasis(
              strong: false,
              children: _parseInlines(text.substring(i + 1, close)),
            ),
          );
          i = close + 1;
          continue;
        }
      }

      buffer.write(c);
      i += 1;
    }

    flush();
    return out;
  }

  /// Matches a `[label](url)` link starting at [start]. Balances nested
  /// brackets/parens minimally.
  static _LinkMatch? _matchLink(String text, int start) {
    int depth = 0;
    int i = start;
    final int n = text.length;
    int? labelEnd;
    // Label between the outermost [ ].
    for (; i < n; i += 1) {
      final String ch = text[i];
      if (ch == '[') {
        depth += 1;
      } else if (ch == ']') {
        depth -= 1;
        if (depth == 0) {
          labelEnd = i;
          break;
        }
      }
    }
    if (labelEnd == null || labelEnd + 1 >= n || text[labelEnd + 1] != '(') {
      return null;
    }
    // URL between the ( ).
    int paren = 0;
    int j = labelEnd + 1;
    int? urlEnd;
    for (; j < n; j += 1) {
      final String ch = text[j];
      if (ch == '(') {
        paren += 1;
      } else if (ch == ')') {
        paren -= 1;
        if (paren == 0) {
          urlEnd = j;
          break;
        }
      }
    }
    if (urlEnd == null) {
      return null;
    }
    return _LinkMatch(
      label: text.substring(start + 1, labelEnd),
      url: text.substring(labelEnd + 2, urlEnd),
      end: urlEnd + 1,
    );
  }

  /// The exclusive end index of the run of [ch] starting at [start].
  static int _matchRun(String text, int start, String ch) {
    int i = start;
    while (i < text.length && text[i] == ch) {
      i += 1;
    }
    return i;
  }

  static bool _isPunctuation(String c) => _punctuation.contains(c);

  static String _normalize(String source) =>
      source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  static const String _punctuation = r'''!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~''';

  static final RegExp _fence = RegExp(r'^\s*(```|~~~)(.*)$');
  static final RegExp _thematicBreak = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');
  static final RegExp _heading = RegExp(r'^\s{0,3}(#{1,6})\s+(.*)$');
  static final RegExp _unordered = RegExp(r'^\s{0,3}[-*+]\s+(.*)$');
  static final RegExp _ordered = RegExp(r'^\s{0,3}\d{1,9}[.)]\s+(.*)$');
  static final RegExp _taskBox = RegExp(r'^\[([ xX])\]\s+');
  // No leading `^`: [Pattern.matchAsPrefix] already anchors the match at the
  // supplied offset, so anchoring the pattern too would be redundant.
  static final RegExp _autolink = RegExp(
    r'<([a-zA-Z][a-zA-Z0-9+.\-]*:[^>\s]+)>',
  );
}

final class _LinkMatch {
  const _LinkMatch({required this.label, required this.url, required this.end});
  final String label;
  final String url;
  final int end;
}
