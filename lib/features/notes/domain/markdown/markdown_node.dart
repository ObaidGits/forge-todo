/// A safe Markdown Abstract Syntax Tree (R-NOTE-001).
///
/// The AST is the neutralized representation of a note body: by the time a body
/// is parsed into these nodes, every dangerous construct has already been
/// defused. Raw HTML never survives as markup (it becomes literal text), links
/// carry an explicit safety verdict, and no node can carry executable content.
/// The full editor/preview UI (task 5.3) renders this tree; task 5.1 provides
/// the tree and the sanitizing parser that produces it.
library;

/// The parsed document: an ordered list of block nodes.
final class MarkdownDocument {
  const MarkdownDocument(this.blocks);

  final List<MarkdownBlock> blocks;

  /// The flattened plain text of the document, used to derive the searchable
  /// body (R-NOTE-004). Block boundaries become single spaces/newlines; markup
  /// characters are dropped.
  String toPlainText() {
    final StringBuffer buffer = StringBuffer();
    for (final MarkdownBlock block in blocks) {
      block.writePlainText(buffer);
    }
    return buffer.toString().trim();
  }

  /// A neutralized, HTML-escaped rendering used by sanitization tests and any
  /// non-Flutter preview. It provably contains no `<script>`, raw HTML markup,
  /// or unsafe link targets.
  String toSafeHtml() {
    final StringBuffer buffer = StringBuffer();
    for (final MarkdownBlock block in blocks) {
      block.writeSafeHtml(buffer);
    }
    return buffer.toString();
  }
}

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------

sealed class MarkdownBlock {
  const MarkdownBlock();

  void writePlainText(StringBuffer out);
  void writeSafeHtml(StringBuffer out);
}

final class MarkdownHeading extends MarkdownBlock {
  const MarkdownHeading({required this.level, required this.inlines});

  final int level;
  final List<MarkdownInline> inlines;

  @override
  void writePlainText(StringBuffer out) {
    _writeInlinePlain(inlines, out);
    out.write('\n');
  }

  @override
  void writeSafeHtml(StringBuffer out) {
    out.write('<h$level>');
    _writeInlineHtml(inlines, out);
    out.write('</h$level>');
  }
}

final class MarkdownParagraph extends MarkdownBlock {
  const MarkdownParagraph(this.inlines);

  final List<MarkdownInline> inlines;

  @override
  void writePlainText(StringBuffer out) {
    _writeInlinePlain(inlines, out);
    out.write('\n');
  }

  @override
  void writeSafeHtml(StringBuffer out) {
    out.write('<p>');
    _writeInlineHtml(inlines, out);
    out.write('</p>');
  }
}

/// A fenced or indented code block. Its content is always literal text and is
/// never interpreted as Markdown or HTML.
final class MarkdownCodeBlock extends MarkdownBlock {
  const MarkdownCodeBlock({required this.text, this.language});

  final String text;
  final String? language;

  @override
  void writePlainText(StringBuffer out) {
    out
      ..write(text)
      ..write('\n');
  }

  @override
  void writeSafeHtml(StringBuffer out) {
    out
      ..write('<pre><code>')
      ..write(_escapeHtml(text))
      ..write('</code></pre>');
  }
}

final class MarkdownBlockQuote extends MarkdownBlock {
  const MarkdownBlockQuote(this.children);

  final List<MarkdownBlock> children;

  @override
  void writePlainText(StringBuffer out) {
    for (final MarkdownBlock child in children) {
      child.writePlainText(out);
    }
  }

  @override
  void writeSafeHtml(StringBuffer out) {
    out.write('<blockquote>');
    for (final MarkdownBlock child in children) {
      child.writeSafeHtml(out);
    }
    out.write('</blockquote>');
  }
}

/// An ordered or unordered list.
final class MarkdownList extends MarkdownBlock {
  const MarkdownList({required this.ordered, required this.items});

  final bool ordered;
  final List<MarkdownListItem> items;

  @override
  void writePlainText(StringBuffer out) {
    for (final MarkdownListItem item in items) {
      item.writePlainText(out);
    }
  }

  @override
  void writeSafeHtml(StringBuffer out) {
    final String tag = ordered ? 'ol' : 'ul';
    out.write('<$tag>');
    for (final MarkdownListItem item in items) {
      item.writeSafeHtml(out);
    }
    out.write('</$tag>');
  }
}

/// A list item, optionally a GitHub-style task checkbox (R-NOTE-001).
final class MarkdownListItem {
  const MarkdownListItem({required this.inlines, this.checkbox});

  final List<MarkdownInline> inlines;

  /// `null` for a plain item; `true`/`false` for a checked/unchecked task box.
  final bool? checkbox;

  bool get isTask => checkbox != null;

  void writePlainText(StringBuffer out) {
    _writeInlinePlain(inlines, out);
    out.write('\n');
  }

  void writeSafeHtml(StringBuffer out) {
    out.write('<li>');
    if (checkbox != null) {
      out.write(
        checkbox!
            ? '<input type="checkbox" checked disabled> '
            : '<input type="checkbox" disabled> ',
      );
    }
    _writeInlineHtml(inlines, out);
    out.write('</li>');
  }
}

final class MarkdownThematicBreak extends MarkdownBlock {
  const MarkdownThematicBreak();

  @override
  void writePlainText(StringBuffer out) {}

  @override
  void writeSafeHtml(StringBuffer out) => out.write('<hr>');
}

// ---------------------------------------------------------------------------
// Inlines
// ---------------------------------------------------------------------------

sealed class MarkdownInline {
  const MarkdownInline();

  void writePlainText(StringBuffer out);
  void writeSafeHtml(StringBuffer out);
}

final class MarkdownText extends MarkdownInline {
  const MarkdownText(this.text);

  final String text;

  @override
  void writePlainText(StringBuffer out) => out.write(text);

  @override
  void writeSafeHtml(StringBuffer out) => out.write(_escapeHtml(text));
}

final class MarkdownEmphasis extends MarkdownInline {
  const MarkdownEmphasis({required this.strong, required this.children});

  final bool strong;
  final List<MarkdownInline> children;

  @override
  void writePlainText(StringBuffer out) => _writeInlinePlain(children, out);

  @override
  void writeSafeHtml(StringBuffer out) {
    final String tag = strong ? 'strong' : 'em';
    out.write('<$tag>');
    _writeInlineHtml(children, out);
    out.write('</$tag>');
  }
}

final class MarkdownCodeSpan extends MarkdownInline {
  const MarkdownCodeSpan(this.text);

  final String text;

  @override
  void writePlainText(StringBuffer out) => out.write(text);

  @override
  void writeSafeHtml(StringBuffer out) {
    out
      ..write('<code>')
      ..write(_escapeHtml(text))
      ..write('</code>');
  }
}

/// A Markdown link. [safe] is `false` when the target used a disallowed scheme
/// (e.g. `javascript:`); an unsafe link renders as plain label text with no
/// navigable target so a malicious URL can never be activated.
final class MarkdownLink extends MarkdownInline {
  const MarkdownLink({
    required this.children,
    required this.href,
    required this.safe,
  });

  final List<MarkdownInline> children;

  /// The sanitized target, or an empty string when the link was neutralized.
  final String href;
  final bool safe;

  @override
  void writePlainText(StringBuffer out) => _writeInlinePlain(children, out);

  @override
  void writeSafeHtml(StringBuffer out) {
    if (!safe || href.isEmpty) {
      // Neutralized: keep the human-readable label, drop the target entirely.
      _writeInlineHtml(children, out);
      return;
    }
    out
      ..write('<a href="')
      ..write(_escapeAttribute(href))
      ..write('">');
    _writeInlineHtml(children, out);
    out.write('</a>');
  }
}

/// A `[[wiki-link]]` to another note by title (R-NOTE-003). Resolution to a
/// concrete note id (and ambiguity handling) is layered on in task 5.2; the
/// span itself is always safe internal navigation.
final class MarkdownWikiLink extends MarkdownInline {
  const MarkdownWikiLink({required this.target, required this.label});

  /// The referenced note title text.
  final String target;

  /// The visible label (equal to [target] when no explicit alias was given).
  final String label;

  @override
  void writePlainText(StringBuffer out) => out.write(label);

  @override
  void writeSafeHtml(StringBuffer out) {
    out
      ..write('<a data-wikilink="')
      ..write(_escapeAttribute(target))
      ..write('">')
      ..write(_escapeHtml(label))
      ..write('</a>');
  }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

void _writeInlinePlain(List<MarkdownInline> inlines, StringBuffer out) {
  for (final MarkdownInline inline in inlines) {
    inline.writePlainText(out);
  }
}

void _writeInlineHtml(List<MarkdownInline> inlines, StringBuffer out) {
  for (final MarkdownInline inline in inlines) {
    inline.writeSafeHtml(out);
  }
}

String _escapeHtml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _escapeAttribute(String value) =>
    _escapeHtml(value).replaceAll('"', '&quot;').replaceAll("'", '&#39;');
