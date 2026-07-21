import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forge/app/navigation/desktop_menu_bar.dart';
import 'package:forge/app/navigation/forge_destination.dart';
import 'package:forge/app/navigation/forge_shortcuts.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/search/presentation/command_palette.dart';
import 'package:go_router/go_router.dart';

final class ForgeScaffold extends StatelessWidget {
  const ForgeScaffold({
    required this.child,
    this.onQuickCapture,
    this.onRequestQuit,
    this.showMenuBar,
    super.key,
  });

  final Widget child;
  final VoidCallback? onQuickCapture;

  /// Routes a File ▸ Quit request through the app's configured close behavior.
  /// When null the menu item is disabled (e.g. non-desktop or tests).
  final VoidCallback? onRequestQuit;

  /// Forces the desktop menu bar on/off. When null it is shown on desktop
  /// platforms only. Tests set this explicitly.
  final bool? showMenuBar;

  bool get _menuBarVisible =>
      showMenuBar ??
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double textScale = MediaQuery.textScalerOf(context).scale(1);
        final _ShellLayout layout = _layoutFor(constraints.maxWidth, textScale);
        final String location = GoRouterState.of(context).uri.path;
        final ForgeDestination selected = ForgeDestination.fromLocation(
          location,
        );
        return Shortcuts(
          shortcuts: forgeShortcuts,
          child: Actions(
            actions: <Type, Action<Intent>>{
              SearchIntent: CallbackAction<SearchIntent>(
                onInvoke: (SearchIntent intent) {
                  context.go('/search');
                  return null;
                },
              ),
              CommandPaletteIntent: CallbackAction<CommandPaletteIntent>(
                onInvoke: (CommandPaletteIntent intent) {
                  _openCommandPalette(context);
                  return null;
                },
              ),
              QuickCaptureIntent: CallbackAction<QuickCaptureIntent>(
                onInvoke: (QuickCaptureIntent intent) {
                  _invokeQuickCapture(context);
                  return null;
                },
              ),
              NewNoteIntent: CallbackAction<NewNoteIntent>(
                onInvoke: (NewNoteIntent intent) {
                  context.go('/notes');
                  return null;
                },
              ),
              ShowShortcutsIntent: CallbackAction<ShowShortcutsIntent>(
                onInvoke: (ShowShortcutsIntent intent) {
                  _showShortcuts(context);
                  return null;
                },
              ),
            },
            child: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: _wrapWithMenuBar(
                context,
                _buildScaffold(context, layout, selected),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _wrapWithMenuBar(BuildContext context, Widget scaffold) {
    if (!_menuBarVisible) {
      return scaffold;
    }
    return DesktopMenuBar(
      actions: DesktopMenuActions(
        onQuickCapture: () => _invokeQuickCapture(context),
        onNewNote: () => context.go('/notes'),
        onSearch: () => context.go('/search'),
        onCommandPalette: () => _openCommandPalette(context),
        onShowShortcuts: () => _showShortcuts(context),
        onAbout: () => _showAbout(context),
        onQuit: onRequestQuit ?? () {},
      ),
      child: scaffold,
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    _ShellLayout layout,
    ForgeDestination selected,
  ) {
    final List<ForgeDestination> destinations = layout == _ShellLayout.large
        ? ForgeDestination.values
        : _compactDestinations;
    final int selectedIndex = _selectedIndex(destinations, selected);
    final Widget content = SafeArea(child: child);
    return Scaffold(
      appBar: AppBar(
        title: Text(selected.label(context.l10n)),
        actions: <Widget>[
          _orderedAction(
            order: 1,
            child: IconButton(
              onPressed: () => context.go('/search'),
              tooltip: context.l10n.actionSearch,
              icon: const Icon(Icons.search),
            ),
          ),
          _orderedAction(
            order: 2,
            child: IconButton(
              onPressed: () => _invokeQuickCapture(context),
              tooltip: context.l10n.actionQuickCapture,
              icon: const Icon(Icons.add),
            ),
          ),
          _orderedAction(
            order: 3,
            child: IconButton(
              onPressed: () => _openCommandPalette(context),
              tooltip: context.l10n.actionCommandPalette,
              icon: const Icon(Icons.bolt_outlined),
            ),
          ),
          _orderedAction(
            order: 4,
            child: IconButton(
              onPressed: () => _showShortcuts(context),
              tooltip: context.l10n.actionShowShortcuts,
              icon: const Icon(Icons.keyboard_outlined),
            ),
          ),
          const SizedBox(width: ForgeSpacing.xs),
        ],
      ),
      body: layout == _ShellLayout.compact
          ? content
          : Row(
              children: <Widget>[
                NavigationRail(
                  extended: layout == _ShellLayout.large,
                  selectedIndex: selectedIndex,
                  labelType: layout == _ShellLayout.large
                      ? NavigationRailLabelType.none
                      : NavigationRailLabelType.all,
                  onDestinationSelected: (int index) =>
                      context.go(destinations[index].location),
                  destinations: destinations
                      .map(
                        (ForgeDestination destination) =>
                            NavigationRailDestination(
                              icon: Icon(destination.icon),
                              selectedIcon: Icon(destination.selectedIcon),
                              label: Text(
                                _labelFor(context, destination, layout),
                              ),
                            ),
                      )
                      .toList(growable: false),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ],
            ),
      bottomNavigationBar: layout == _ShellLayout.compact
          ? NavigationBar(
              selectedIndex: selectedIndex,
              onDestinationSelected: (int index) =>
                  context.go(destinations[index].location),
              destinations: destinations
                  .map(
                    (ForgeDestination destination) => NavigationDestination(
                      icon: Icon(destination.icon),
                      selectedIcon: Icon(destination.selectedIcon),
                      label: _labelFor(context, destination, layout),
                    ),
                  )
                  .toList(growable: false),
            )
          : null,
    );
  }

  Widget _orderedAction({required double order, required Widget child}) {
    return FocusTraversalOrder(
      order: NumericFocusOrder(order),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: ForgeSizes.minimumInteractiveDimension,
          minHeight: ForgeSizes.minimumInteractiveDimension,
        ),
        child: child,
      ),
    );
  }

  String _labelFor(
    BuildContext context,
    ForgeDestination destination,
    _ShellLayout layout,
  ) {
    if (layout != _ShellLayout.large && destination == ForgeDestination.goals) {
      return context.l10n.navProgress;
    }
    return destination.label(context.l10n);
  }

  int _selectedIndex(
    List<ForgeDestination> destinations,
    ForgeDestination selected,
  ) {
    if (destinations == _compactDestinations) {
      if (<ForgeDestination>{
        ForgeDestination.goals,
        ForgeDestination.learn,
        ForgeDestination.habits,
      }.contains(selected)) {
        return 2;
      }
      if (<ForgeDestination>{
        ForgeDestination.planner,
        ForgeDestination.focus,
        ForgeDestination.settings,
      }.contains(selected)) {
        return 4;
      }
    }
    final int index = destinations.indexOf(selected);
    return index < 0 ? 0 : index;
  }

  void _openCommandPalette(BuildContext context) {
    unawaited(
      showCommandPalette(
        context,
        onQuickCapture: () => _invokeQuickCapture(context),
      ),
    );
  }

  void _invokeQuickCapture(BuildContext context) {
    if (onQuickCapture case final VoidCallback callback) {
      callback();
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.routePlaceholder)));
  }

  void _showShortcuts(BuildContext context) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: Text(dialogContext.l10n.actionShowShortcuts),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final String entry in forgeShortcutHelpEntries(
                  dialogContext.l10n,
                )) ...<Widget>[
                  Text(entry),
                  const SizedBox(height: ForgeSpacing.sm),
                ],
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(dialogContext.l10n.actionClose),
            ),
          ],
        ),
      ),
    );
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: context.l10n.appName,
      applicationVersion: _appVersion,
      applicationLegalese: context.l10n.tagline,
    );
  }

  /// The user-facing app version shown in the About dialog. Kept in sync with
  /// pubspec via the release build; hardcoded here for the shell.
  static const String _appVersion = '0.1.0';

  static const List<ForgeDestination> _compactDestinations = <ForgeDestination>[
    ForgeDestination.today,
    ForgeDestination.tasks,
    ForgeDestination.goals,
    ForgeDestination.notes,
    ForgeDestination.settings,
  ];

  static _ShellLayout _layoutFor(double width, double textScale) {
    if (width < ForgeBreakpoints.compact ||
        (textScale >= 2 && width < ForgeBreakpoints.expanded)) {
      return _ShellLayout.compact;
    }
    if (width < ForgeBreakpoints.large || textScale >= 2) {
      return _ShellLayout.medium;
    }
    return _ShellLayout.large;
  }
}

enum _ShellLayout { compact, medium, large }
