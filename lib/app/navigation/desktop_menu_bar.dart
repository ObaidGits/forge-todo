import 'package:flutter/material.dart';
import 'package:forge/app/navigation/forge_destination.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

/// The shell actions the desktop menu bar invokes. Navigation is handled inline
/// via [GoRouter]; these are the non-navigation commands the shell owns.
final class DesktopMenuActions {
  const DesktopMenuActions({
    required this.onQuickCapture,
    required this.onNewNote,
    required this.onSearch,
    required this.onCommandPalette,
    required this.onShowShortcuts,
    required this.onAbout,
    required this.onQuit,
  });

  final VoidCallback onQuickCapture;
  final VoidCallback onNewNote;
  final VoidCallback onSearch;
  final VoidCallback onCommandPalette;
  final VoidCallback onShowShortcuts;
  final VoidCallback onAbout;

  /// Requests application quit, routed through the configured close behavior.
  final VoidCallback onQuit;
}

/// A native-style desktop application menu bar (ux-design §9: "Menus expose
/// File (backup/import/export), Edit, View, Navigate, Help/shortcuts.").
///
/// It is wired to the existing routes and shell actions — it forks no logic.
/// Every item is keyboard operable and carries an accessible name; the menu
/// bar participates in normal focus traversal (NFR-A11Y-001, NFR-A11Y-003).
/// Companion/floating windows remain Post-V1 and are intentionally absent.
final class DesktopMenuBar extends StatelessWidget {
  const DesktopMenuBar({required this.actions, required this.child, super.key});

  final DesktopMenuActions actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Column(
      children: <Widget>[
        MenuBar(
          children: <Widget>[
            SubmenuButton(
              menuChildren: <Widget>[
                _item(l10n.menuQuickCapture, actions.onQuickCapture),
                _item(l10n.menuNewNote, actions.onNewNote),
                _item(l10n.menuBackupData, () => context.go('/settings')),
                _item(l10n.menuImportExport, () => context.go('/settings')),
                _item(l10n.menuQuit, actions.onQuit),
              ],
              child: Text(l10n.menuFile),
            ),
            SubmenuButton(
              menuChildren: <Widget>[
                _item(l10n.menuFind, actions.onSearch),
                _item(l10n.menuCommandPalette, actions.onCommandPalette),
              ],
              child: Text(l10n.menuEdit),
            ),
            SubmenuButton(
              menuChildren: <Widget>[
                _item(l10n.menuSearch, actions.onSearch),
                _item(l10n.menuCommandPalette, actions.onCommandPalette),
              ],
              child: Text(l10n.menuView),
            ),
            SubmenuButton(
              menuChildren: <Widget>[
                for (final ForgeDestination destination
                    in ForgeDestination.values)
                  _item(
                    destination.label(l10n),
                    () => context.go(destination.location),
                  ),
              ],
              child: Text(l10n.menuNavigate),
            ),
            SubmenuButton(
              menuChildren: <Widget>[
                _item(l10n.actionShowShortcuts, actions.onShowShortcuts),
                _item(l10n.menuAbout, actions.onAbout),
              ],
              child: Text(l10n.menuHelp),
            ),
          ],
        ),
        Expanded(child: child),
      ],
    );
  }

  Widget _item(String label, VoidCallback onPressed) =>
      MenuItemButton(onPressed: onPressed, child: Text(label));
}
