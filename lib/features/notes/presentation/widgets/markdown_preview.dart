import 'package:flutter/material.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/features/notes/domain/markdown/markdown_node.dart';
import 'package:forge/features/notes/domain/markdown/safe_markdown.dart';

/// Rendering limits that keep a very large note responsive (R-NOTE-001,
/// NFR-PERF budgets). The preview is virtualized (only visible blocks build),
/// and parsing is bounded to [previewCharacterLimit] characters so an
/// adversarially large body cannot stall the UI thread. The full body always
/// remains editable and is saved verbatim; only the *preview* is truncated.
abstract final class MarkdownPreviewLimits {
  static const int previewCharacterLimit = 100000;
}

/// Renders a neutralized Markdown body to accessible Flutter widgets
/// (R-NOTE-001, NFR-A11Y-001/003).
///
/// The body is parsed by the security-first [SafeMarkdown] parser, so by the
/// time this widget sees the AST every dangerous construct is already defused:
/// raw HTML is literal text and unsafe link targets are neutralized. This
/// widget adds the presentation contract on top: headings expose header
/// semantics, links expose link semantics and route through the supplied
/// callbacks (never opened directly here), task checkboxes render with checked
/// state, and code blocks scroll horizontally rather than overflowing the page
/// (ux-design §11). Blocks render through a virtualized list so large notes
/// stay responsive.
final class MarkdownPreview extends StatefulWidget {
  const MarkdownPreview({
    required this.body,
    this.onWikiLink,
    this.onExternalLink,
    this.largeDocumentNotice,
    this.emptyPlaceholder,
    this.padding = const EdgeInsets.all(ForgeSpacing.md),
    super.key,
  });

  final String body;

  /// Invoked for an in-app `[[wiki-link]]` navigation (R-NOTE-003).
  final Future<void> Function(String target)? onWikiLink;

  /// Invoked for a safe external link; the handler enforces [UriPolicy] and
  /// user-initiation before any OS handoff (R-SEC-005).
  final Future<void> Function(String href)? onExternalLink;

  /// Shown when the body was truncated for preview.
  final String? largeDocumentNotice;

  /// Shown when the body has no renderable content.
  final String? emptyPlaceholder;

  final EdgeInsets padding;

  @override
  State<MarkdownPreview> createState() => _MarkdownPreviewState();
}

class _MarkdownPreviewState extends State<MarkdownPreview> {
  late MarkdownDocument _document;
  late bool _truncated;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(MarkdownPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.body != widget.body) {
      _parse();
    }
  }

  void _parse() {
    _truncated =
        widget.body.length > MarkdownPreviewLimits.previewCharacterLimit;
    final String source = _truncated
        ? widget.body.substring(0, MarkdownPreviewLimits.previewCharacterLimit)
        : widget.body;
    _document = SafeMarkdown.parse(source);
  }

  @override
  Widget build(BuildContext context) {
    final List<MarkdownBlock> blocks = _document.blocks;
    if (blocks.isEmpty && !_truncated) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(ForgeSpacing.xl),
          child: Text(
            widget.emptyPlaceholder ?? '',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    final int noticeCount = _truncated && widget.largeDocumentNotice != null
        ? 1
        : 0;

    return ListView.builder(
      restorationId: 'content-note-preview',
      padding: widget.padding,
      itemCount: blocks.length + noticeCount,
      itemBuilder: (BuildContext context, int index) {
        if (noticeCount == 1 && index == 0) {
          return _LargeDocumentNotice(message: widget.largeDocumentNotice!);
        }
        final MarkdownBlock block = blocks[index - noticeCount];
        return Padding(
          padding: const EdgeInsets.only(bottom: ForgeSpacing.xs),
          child: _MarkdownBlockView(
            block: block,
            onWikiLink: widget.onWikiLink,
            onExternalLink: widget.onExternalLink,
          ),
        );
      },
    );
  }
}

final class _LargeDocumentNotice extends StatelessWidget {
  const _LargeDocumentNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: ForgeSpacing.sm),
      padding: const EdgeInsets.all(ForgeSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(ForgeRadii.card),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.info_outline, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: ForgeSpacing.xs),
          Expanded(child: Text(message, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// Renders one Markdown block. Kept as its own widget so the virtualized list
/// can recycle blocks and so link semantics stay local to the block.
final class _MarkdownBlockView extends StatelessWidget {
  const _MarkdownBlockView({
    required this.block,
    this.onWikiLink,
    this.onExternalLink,
  });

  final MarkdownBlock block;
  final Future<void> Function(String target)? onWikiLink;
  final Future<void> Function(String href)? onExternalLink;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    switch (block) {
      case MarkdownHeading(level: final int level, inlines: final inlines):
        return Semantics(
          header: true,
          child: Text.rich(
            TextSpan(children: _spans(context, inlines)),
            style: _headingStyle(theme, level),
          ),
        );
      case MarkdownParagraph(inlines: final inlines):
        return Text.rich(
          TextSpan(children: _spans(context, inlines)),
          style: theme.textTheme.bodyLarge,
        );
      case MarkdownCodeBlock(text: final String code):
        return _CodeBlock(code: code);
      case MarkdownBlockQuote(children: final children):
        return Container(
          padding: const EdgeInsets.only(left: ForgeSpacing.sm),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 3,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final MarkdownBlock child in children)
                _MarkdownBlockView(
                  block: child,
                  onWikiLink: onWikiLink,
                  onExternalLink: onExternalLink,
                ),
            ],
          ),
        );
      case MarkdownList(ordered: final bool ordered, items: final items):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int i = 0; i < items.length; i += 1)
              _listItem(context, items[i], ordered, i + 1),
          ],
        );
      case MarkdownThematicBreak():
        return const Divider();
    }
  }

  Widget _listItem(
    BuildContext context,
    MarkdownListItem item,
    bool ordered,
    int number,
  ) {
    final ThemeData theme = Theme.of(context);
    final Widget marker;
    if (item.isTask) {
      final bool checked = item.checkbox!;
      marker = Semantics(
        checked: checked,
        child: Icon(
          checked ? Icons.check_box : Icons.check_box_outline_blank,
          size: 20,
          color: theme.colorScheme.primary,
        ),
      );
    } else if (ordered) {
      marker = Text('$number.', style: theme.textTheme.bodyLarge);
    } else {
      marker = Text('•', style: theme.textTheme.bodyLarge);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ForgeSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: ForgeSpacing.xs, top: 2),
            child: marker,
          ),
          Expanded(
            child: Text.rich(
              TextSpan(children: _spans(context, item.inlines)),
              style: theme.textTheme.bodyLarge,
            ),
          ),
        ],
      ),
    );
  }

  List<InlineSpan> _spans(BuildContext context, List<MarkdownInline> inlines) {
    final ThemeData theme = Theme.of(context);
    final List<InlineSpan> spans = <InlineSpan>[];
    for (final MarkdownInline inline in inlines) {
      switch (inline) {
        case MarkdownText(text: final String text):
          spans.add(TextSpan(text: text));
        case MarkdownEmphasis(strong: final bool strong, children: final kids):
          spans.add(
            TextSpan(
              style: strong
                  ? const TextStyle(fontWeight: FontWeight.bold)
                  : const TextStyle(fontStyle: FontStyle.italic),
              children: _spans(context, kids),
            ),
          );
        case MarkdownCodeSpan(text: final String text):
          spans.add(
            TextSpan(
              text: text,
              style: TextStyle(
                fontFamily: 'monospace',
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
          );
        case MarkdownLink(
          children: final kids,
          href: final String href,
          safe: final bool safe,
        ):
          if (safe && href.isNotEmpty && onExternalLink != null) {
            spans.add(
              _linkSpan(
                context,
                label: _plainOf(kids),
                onTap: () => onExternalLink!(href),
              ),
            );
          } else {
            // Neutralized link: keep the label, drop the target.
            spans.addAll(_spans(context, kids));
          }
        case MarkdownWikiLink(target: final String target, label: final label):
          if (onWikiLink != null) {
            spans.add(
              _linkSpan(
                context,
                label: label,
                onTap: () => onWikiLink!(target),
              ),
            );
          } else {
            spans.add(TextSpan(text: label));
          }
      }
    }
    return spans;
  }

  InlineSpan _linkSpan(
    BuildContext context, {
    required String label,
    required Future<void> Function() onTap,
  }) {
    final ThemeData theme = Theme.of(context);
    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: Semantics(
        link: true,
        child: InkWell(
          onTap: () => onTap(),
          child: Text(
            label,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ),
    );
  }

  static String _plainOf(List<MarkdownInline> inlines) {
    final StringBuffer buffer = StringBuffer();
    for (final MarkdownInline inline in inlines) {
      inline.writePlainText(buffer);
    }
    return buffer.toString();
  }

  TextStyle? _headingStyle(ThemeData theme, int level) => switch (level) {
    1 => theme.textTheme.headlineMedium,
    2 => theme.textTheme.headlineSmall,
    3 => theme.textTheme.titleLarge,
    4 => theme.textTheme.titleMedium,
    _ => theme.textTheme.titleSmall,
  };
}

/// A code block that scrolls horizontally so long lines never force the page to
/// overflow (ux-design §11). Content is literal text; the parser guarantees it
/// is never interpreted as markup.
final class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(ForgeSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(ForgeRadii.control),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(code, style: const TextStyle(fontFamily: 'monospace')),
      ),
    );
  }
}
