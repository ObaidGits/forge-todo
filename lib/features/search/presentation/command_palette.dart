import 'package:flutter/material.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

/// One keyboard-invocable command in the palette.
final class CommandPaletteEntry {
  const CommandPaletteEntry({
    required this.id,
    required this.label,
    required this.icon,
    required this.run,
  });

  final String id;
  final String label;
  final IconData icon;
  final void Function(BuildContext context) run;
}

/// Opens the command palette: a keyboard-driven launcher for navigation and
/// quick actions (R-SEARCH-004).
///
/// The palette is reachable from every main route (via the app-shell shortcut
/// and app-bar action), is fully keyboard operable — focus lands on the filter
/// field, typing narrows the list, and Enter runs the top match — and every
/// entry carries an accessible name (NFR-A11Y-001).
Future<void> showCommandPalette(
  BuildContext context, {
  VoidCallback? onQuickCapture,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _CommandPaletteDialog(onQuickCapture: onQuickCapture),
  );
}

/// Builds the default command set: navigation to each main destination plus the
/// core quick actions.
List<CommandPaletteEntry> buildDefaultCommands(
  AppLocalizations l10n, {
  VoidCallback? onQuickCapture,
}) {
  void go(BuildContext context, String location) => context.go(location);
  return <CommandPaletteEntry>[
    CommandPaletteEntry(
      id: 'search',
      label: l10n.commandOpenSearch,
      icon: Icons.search,
      run: (BuildContext c) => go(c, '/search'),
    ),
    CommandPaletteEntry(
      id: 'quick-capture',
      label: l10n.commandQuickCapture,
      icon: Icons.add,
      run: (_) => onQuickCapture?.call(),
    ),
    CommandPaletteEntry(
      id: 'today',
      label: l10n.commandGoTo(l10n.navToday),
      icon: Icons.today_outlined,
      run: (BuildContext c) => go(c, '/today'),
    ),
    CommandPaletteEntry(
      id: 'tasks',
      label: l10n.commandGoTo(l10n.navTasks),
      icon: Icons.checklist_outlined,
      run: (BuildContext c) => go(c, '/tasks'),
    ),
    CommandPaletteEntry(
      id: 'goals',
      label: l10n.commandGoTo(l10n.navGoals),
      icon: Icons.flag_outlined,
      run: (BuildContext c) => go(c, '/goals'),
    ),
    CommandPaletteEntry(
      id: 'learn',
      label: l10n.commandGoTo(l10n.navLearn),
      icon: Icons.school_outlined,
      run: (BuildContext c) => go(c, '/learn'),
    ),
    CommandPaletteEntry(
      id: 'habits',
      label: l10n.commandGoTo(l10n.navHabits),
      icon: Icons.event_repeat_outlined,
      run: (BuildContext c) => go(c, '/habits'),
    ),
    CommandPaletteEntry(
      id: 'notes',
      label: l10n.commandGoTo(l10n.navNotes),
      icon: Icons.note_outlined,
      run: (BuildContext c) => go(c, '/notes'),
    ),
    CommandPaletteEntry(
      id: 'planner',
      label: l10n.commandGoTo(l10n.navPlanner),
      icon: Icons.calendar_month_outlined,
      run: (BuildContext c) => go(c, '/planner'),
    ),
    CommandPaletteEntry(
      id: 'focus',
      label: l10n.commandGoTo(l10n.navFocus),
      icon: Icons.timer_outlined,
      run: (BuildContext c) => go(c, '/focus'),
    ),
    CommandPaletteEntry(
      id: 'settings',
      label: l10n.commandOpenSettings,
      icon: Icons.settings_outlined,
      run: (BuildContext c) => go(c, '/settings'),
    ),
    CommandPaletteEntry(
      id: 'areas',
      label: l10n.commandManageAreas,
      icon: Icons.category_outlined,
      run: (BuildContext c) => go(c, '/settings/areas'),
    ),
  ];
}

class _CommandPaletteDialog extends StatefulWidget {
  const _CommandPaletteDialog({this.onQuickCapture});

  final VoidCallback? onQuickCapture;

  @override
  State<_CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<_CommandPaletteDialog> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final List<CommandPaletteEntry> all = buildDefaultCommands(
      l10n,
      onQuickCapture: widget.onQuickCapture,
    );
    final List<CommandPaletteEntry> matches = _filter(all, _query);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: ForgeSizes.formMaxWidth,
          maxHeight: 480,
        ),
        child: Semantics(
          label: l10n.commandPaletteLabel,
          container: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(ForgeSpacing.md),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l10n.commandPaletteTitle,
                    hintText: l10n.commandPaletteHint,
                    prefixIcon: const Icon(Icons.bolt_outlined),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (String value) => setState(() => _query = value),
                  onSubmitted: (_) {
                    if (matches.isNotEmpty) {
                      _activate(matches.first);
                    }
                  },
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: matches.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(ForgeSpacing.lg),
                        child: Text(l10n.commandPaletteEmpty),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: matches.length,
                        itemBuilder: (BuildContext context, int index) {
                          final CommandPaletteEntry entry = matches[index];
                          return ListTile(
                            leading: Icon(entry.icon),
                            title: Text(entry.label),
                            onTap: () => _activate(entry),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _activate(CommandPaletteEntry entry) {
    Navigator.of(context).pop();
    entry.run(context);
  }

  List<CommandPaletteEntry> _filter(
    List<CommandPaletteEntry> all,
    String query,
  ) {
    final String q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return all;
    }
    return all
        .where((CommandPaletteEntry e) => e.label.toLowerCase().contains(q))
        .toList(growable: false);
  }
}
