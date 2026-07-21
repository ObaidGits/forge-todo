import 'package:flutter/material.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/home/domain/home_section.dart';

/// A reorderable, hideable Today section container (SectionCard, R-HOME-002).
///
/// The header is a semantic heading with an optional count and a keyboard-
/// reachable actions menu (move up/down, hide). It collapses only by user
/// intent or emptiness — an empty section is simply not built by the caller.
final class HomeSectionCard extends StatelessWidget {
  const HomeSectionCard({
    required this.kind,
    required this.title,
    required this.child,
    this.count,
    this.onMoveUp,
    this.onMoveDown,
    this.onHide,
    super.key,
  });

  final HomeSectionKind kind;
  final String title;
  final Widget child;
  final int? count;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback? onHide;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasMenu =
        onMoveUp != null || onMoveDown != null || onHide != null;

    return Card(
      margin: const EdgeInsets.only(bottom: ForgeSpacing.md),
      child: Padding(
        padding: const EdgeInsets.all(ForgeSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      count == null ? title : '$title · $count',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ),
                if (hasMenu)
                  PopupMenuButton<_SectionAction>(
                    tooltip: context.l10n.homeCustomize,
                    icon: const Icon(Icons.more_vert),
                    onSelected: (_SectionAction action) {
                      switch (action) {
                        case _SectionAction.moveUp:
                          onMoveUp?.call();
                        case _SectionAction.moveDown:
                          onMoveDown?.call();
                        case _SectionAction.hide:
                          onHide?.call();
                      }
                    },
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<_SectionAction>>[
                          if (onMoveUp != null)
                            PopupMenuItem<_SectionAction>(
                              value: _SectionAction.moveUp,
                              child: Text(context.l10n.homeMoveSectionUp),
                            ),
                          if (onMoveDown != null)
                            PopupMenuItem<_SectionAction>(
                              value: _SectionAction.moveDown,
                              child: Text(context.l10n.homeMoveSectionDown),
                            ),
                          if (onHide != null)
                            PopupMenuItem<_SectionAction>(
                              value: _SectionAction.hide,
                              child: Text(context.l10n.homeHideSection),
                            ),
                        ],
                  ),
              ],
            ),
            const SizedBox(height: ForgeSpacing.xs),
            child,
          ],
        ),
      ),
    );
  }
}

enum _SectionAction { moveUp, moveDown, hide }
