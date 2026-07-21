import 'package:flutter/material.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/notes/presentation/markdown_editing.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// The Markdown formatting toolbar (R-NOTE-001).
///
/// Every button maps to a [MarkdownCommand] with an equivalent keyboard command
/// wired by the editor (ux-design §4, NFR-A11Y-001). Each control carries a
/// text tooltip/semantic label and a 48×48 dp hit target, and color is never
/// the sole signal — the icon always pairs with an accessible name.
final class MarkdownToolbar extends StatelessWidget {
  const MarkdownToolbar({
    required this.onCommand,
    this.enabled = true,
    super.key,
  });

  /// Invoked with the chosen command. The editor applies it to the current
  /// selection.
  final void Function(MarkdownCommand command) onCommand;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Semantics(
      container: true,
      label: l10n.noteFormattingToolbar,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            _button(
              context,
              icon: Icons.format_bold,
              label: l10n.noteFormatBold,
              command: MarkdownCommand.bold,
            ),
            _button(
              context,
              icon: Icons.format_italic,
              label: l10n.noteFormatItalic,
              command: MarkdownCommand.italic,
            ),
            _button(
              context,
              icon: Icons.title,
              label: l10n.noteFormatHeading,
              command: MarkdownCommand.heading,
            ),
            _button(
              context,
              icon: Icons.format_list_bulleted,
              label: l10n.noteFormatBulletList,
              command: MarkdownCommand.bulletList,
            ),
            _button(
              context,
              icon: Icons.check_box_outlined,
              label: l10n.noteFormatCheckbox,
              command: MarkdownCommand.checkbox,
            ),
            _button(
              context,
              icon: Icons.code,
              label: l10n.noteFormatCode,
              command: MarkdownCommand.code,
            ),
            _button(
              context,
              icon: Icons.link,
              label: l10n.noteFormatLink,
              command: MarkdownCommand.link,
            ),
          ],
        ),
      ),
    );
  }

  Widget _button(
    BuildContext context, {
    required IconData icon,
    required String label,
    required MarkdownCommand command,
  }) {
    return IconButton(
      icon: Icon(icon),
      tooltip: label,
      onPressed: enabled ? () => onCommand(command) : null,
      // The default IconButton constraints already meet 48×48; keep it explicit.
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    );
  }
}
