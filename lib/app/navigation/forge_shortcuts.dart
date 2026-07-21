import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

// ---------------------------------------------------------------------------
// Shell intents. One shared definition so the app-shell Shortcuts map, the
// desktop menu bar, and the shortcuts help dialog never drift (ux-design §4,
// R-SEARCH-004: quick capture reachable from every main route).
// ---------------------------------------------------------------------------

final class SearchIntent extends Intent {
  const SearchIntent();
}

final class QuickCaptureIntent extends Intent {
  const QuickCaptureIntent();
}

final class NewNoteIntent extends Intent {
  const NewNoteIntent();
}

final class ShowShortcutsIntent extends Intent {
  const ShowShortcutsIntent();
}

final class CommandPaletteIntent extends Intent {
  const CommandPaletteIntent();
}

/// The canonical desktop shortcut map, bound once by the app shell.
///
/// Both the Control (Windows/Linux) and Meta/Command (macOS) chords are
/// registered for each action so the same shell works across desktop platforms
/// without per-platform branching.
const Map<ShortcutActivator, Intent>
forgeShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.keyK, control: true): SearchIntent(),
  SingleActivator(LogicalKeyboardKey.keyK, meta: true): SearchIntent(),
  SingleActivator(LogicalKeyboardKey.keyN, control: true): QuickCaptureIntent(),
  SingleActivator(LogicalKeyboardKey.keyN, meta: true): QuickCaptureIntent(),
  SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true):
      NewNoteIntent(),
  SingleActivator(LogicalKeyboardKey.keyN, meta: true, shift: true):
      NewNoteIntent(),
  SingleActivator(LogicalKeyboardKey.slash, shift: true): ShowShortcutsIntent(),
  SingleActivator(LogicalKeyboardKey.keyP, control: true, shift: true):
      CommandPaletteIntent(),
  SingleActivator(LogicalKeyboardKey.keyP, meta: true, shift: true):
      CommandPaletteIntent(),
};

/// The ordered, human-readable shortcut lines shown in the Help ▸ Keyboard
/// shortcuts dialog. Discoverability is a WCAG obligation (NFR-A11Y-003:
/// "shortcut discoverability ... SHALL be tested").
List<String> forgeShortcutHelpEntries(AppLocalizations l10n) => <String>[
  l10n.shortcutSearch,
  l10n.shortcutQuickCapture,
  l10n.shortcutCommandPalette,
  l10n.shortcutNote,
  l10n.shortcutNavigate,
  l10n.shortcutActivate,
  l10n.shortcutToggle,
  l10n.shortcutSelectAll,
  l10n.shortcutHelp,
];
