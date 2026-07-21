import 'package:flutter/material.dart';
import 'package:forge/core/ui/forge_tokens.dart';

/// A calm, accessible empty state (ux-design §6, §1 "calm, not empty").
///
/// Empty content renders immediately with concise text and at most one action;
/// no decorative illustration is required for core screens. Title and body are
/// merged so assistive technology announces the state as one coherent message,
/// while the title stays a heading for screen-reader/keyboard navigation. Any
/// glyph is decorative and hidden from assistive technology because the text
/// carries the meaning and color is never the sole signal (`NFR-A11Y-001`,
/// `NFR-A11Y-003`).
final class ForgeEmptyState extends StatelessWidget {
  const ForgeEmptyState({
    required this.title,
    required this.body,
    this.icon,
    this.action,
    this.compact = false,
    super.key,
  });

  /// Short heading describing the empty state.
  final String title;

  /// One sentence explaining what to do next.
  final String body;

  /// Optional decorative glyph, hidden from assistive technology.
  final IconData? icon;

  /// Optional single primary action.
  final Widget? action;

  /// When true, uses a tighter inline layout suitable for a collapsed section
  /// rather than a full-screen centered state.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CrossAxisAlignment crossAxis = compact
        ? CrossAxisAlignment.start
        : CrossAxisAlignment.center;
    final TextAlign textAlign = compact ? TextAlign.start : TextAlign.center;

    final Widget message = MergeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: crossAxis,
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              title,
              style: theme.textTheme.titleMedium,
              textAlign: textAlign,
            ),
          ),
          const SizedBox(height: ForgeSpacing.xs),
          Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: textAlign,
          ),
        ],
      ),
    );

    final Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: crossAxis,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          ExcludeSemantics(
            child: Icon(
              icon,
              size: ForgeSizes.minimumInteractiveDimension,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: ForgeSpacing.md),
        ],
        message,
        if (action != null) ...<Widget>[
          const SizedBox(height: ForgeSpacing.lg),
          action!,
        ],
      ],
    );

    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: ForgeSpacing.xl),
        child: content,
      );
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(ForgeSpacing.lg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: content,
        ),
      ),
    );
  }
}
