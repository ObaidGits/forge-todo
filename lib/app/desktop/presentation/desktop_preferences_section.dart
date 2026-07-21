import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/desktop/autostart_controller.dart';
import 'package:forge/app/desktop/close_behavior.dart';
import 'package:forge/app/desktop/desktop_providers.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_controller.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_preferences.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// True on the desktop target platforms Forge ships (ux-design §9).
bool get isDesktopPlatform =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// The Settings ▸ Desktop preferences group.
///
/// Exposes the explicit, user-configurable close behavior (ux-design §9) and
/// the desktop "sticky widget" controls (task §7): enable, always-on-top,
/// start-on-login, opacity, lock position, which tabs, and a "Show widget now"
/// action. All are keyboard-operable with 48-dp targets and never rely on color
/// alone (NFR-A11Y-001/002/003). Shown on desktop only; [forceShow] lets tests
/// render it on any platform.
final class DesktopPreferencesSection extends ConsumerWidget {
  const DesktopPreferencesSection({this.forceShow = false, super.key});

  final bool forceShow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!forceShow && !isDesktopPlatform) {
      return const SizedBox.shrink();
    }
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final AsyncValue<CloseBehavior> behavior = ref.watch(closeBehaviorProvider);
    final CloseBehavior current = switch (behavior) {
      AsyncData<CloseBehavior>(:final CloseBehavior value) => value,
      _ => CloseBehavior.exitApp,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ForgeSpacing.md,
            ForgeSpacing.md,
            ForgeSpacing.md,
            ForgeSpacing.xxs,
          ),
          child: Semantics(
            header: true,
            child: Text(
              l10n.settingsSectionDesktop,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: ForgeSpacing.md),
          child: Text(
            l10n.settingsCloseBehaviorSubtitle,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        RadioGroup<CloseBehavior>(
          groupValue: current,
          onChanged: (CloseBehavior? next) {
            if (next != null) {
              unawaited(ref.read(closeBehaviorProvider.notifier).set(next));
            }
          },
          child: Column(
            children: <Widget>[
              RadioListTile<CloseBehavior>(
                value: CloseBehavior.exitApp,
                title: Text(l10n.settingsCloseBehaviorQuit),
              ),
              RadioListTile<CloseBehavior>(
                value: CloseBehavior.minimizeToTray,
                title: Text(l10n.settingsCloseBehaviorTray),
              ),
            ],
          ),
        ),
        const _DesktopWidgetSettings(),
      ],
    );
  }
}

/// The desktop "sticky widget" preference controls (task §7). Reads and writes
/// [DesktopWidgetPreferences] through the widget controller so changes apply
/// live to a showing widget and persist across launches.
class _DesktopWidgetSettings extends ConsumerWidget {
  const _DesktopWidgetSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final DesktopWidgetState widgetState = ref.watch(
      desktopWidgetControllerProvider,
    );
    final DesktopWidgetPreferences prefs = widgetState.preferences;
    final DesktopWidgetController controller = ref.read(
      desktopWidgetControllerProvider.notifier,
    );

    Future<void> update(DesktopWidgetPreferences next) =>
        controller.updatePreferences(next);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: ForgeSpacing.xs),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: ForgeSpacing.md),
          child: Semantics(
            header: true,
            child: Text(
              'Desktop widget',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
        SwitchListTile(
          value: prefs.enabled,
          title: const Text('Enable desktop widget'),
          subtitle: const Text(
            'A small always-available sticky for today\u2019s tasks and quick notes.',
          ),
          onChanged: (bool value) =>
              unawaited(update(prefs.copyWith(enabled: value))),
        ),
        // The rest of the controls only matter when the widget is enabled.
        SwitchListTile(
          value: prefs.alwaysOnTop,
          title: const Text('Display over other apps'),
          subtitle: const Text(
            'Keep the widget floating on top (best-effort).',
          ),
          onChanged: prefs.enabled
              ? (bool value) =>
                    unawaited(update(prefs.copyWith(alwaysOnTop: value)))
              : null,
        ),
        _AutostartTile(
          startOnLogin: prefs.startOnLogin,
          enabled: prefs.enabled,
          onChanged: (bool value) async {
            final AutostartController autostart = ref.read(
              autostartControllerProvider,
            );
            if (value) {
              await autostart.enable();
            } else {
              await autostart.disable();
            }
            await update(prefs.copyWith(startOnLogin: value));
          },
        ),
        SwitchListTile(
          value:
              ref.watch(closeBehaviorProvider).value ==
              CloseBehavior.minimizeToTray,
          title: const Text('Close to tray'),
          subtitle: const Text(
            'Closing the main window hides Forge to the tray instead of quitting.',
          ),
          onChanged: (bool value) => unawaited(
            ref
                .read(closeBehaviorProvider.notifier)
                .set(
                  value ? CloseBehavior.minimizeToTray : CloseBehavior.exitApp,
                ),
          ),
        ),
        SwitchListTile(
          value: prefs.lockPosition,
          title: const Text('Lock widget position'),
          subtitle: const Text('Disable dragging so the widget stays put.'),
          onChanged: prefs.enabled
              ? (bool value) =>
                    unawaited(update(prefs.copyWith(lockPosition: value)))
              : null,
        ),
        SwitchListTile(
          value: prefs.hotkeyEnabled,
          title: const Text('Global hotkey (Ctrl+Alt+T)'),
          subtitle: const Text(
            'Show or hide the widget from anywhere. Some Linux sessions '
            '(Wayland) may not allow global shortcuts.',
          ),
          onChanged: (bool value) =>
              unawaited(update(prefs.copyWith(hotkeyEnabled: value))),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ForgeSpacing.md,
            ForgeSpacing.xs,
            ForgeSpacing.md,
            0,
          ),
          child: Text('Widget opacity', style: theme.textTheme.bodyMedium),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: ForgeSpacing.sm),
          child: Slider(
            value: prefs.opacity,
            min: DesktopWidgetPreferences.minOpacity,
            max: 1.0,
            divisions: 14,
            label: '${(prefs.opacity * 100).round()}%',
            onChanged: prefs.enabled
                ? (double value) =>
                      unawaited(update(prefs.copyWith(opacity: value)))
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ForgeSpacing.md,
            ForgeSpacing.xs,
            ForgeSpacing.md,
            ForgeSpacing.xxs,
          ),
          child: Text('Tabs to show', style: theme.textTheme.bodyMedium),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: ForgeSpacing.md),
          child: SegmentedButton<WidgetTabs>(
            segments: const <ButtonSegment<WidgetTabs>>[
              ButtonSegment<WidgetTabs>(
                value: WidgetTabs.today,
                label: Text('Today'),
              ),
              ButtonSegment<WidgetTabs>(
                value: WidgetTabs.notes,
                label: Text('Notes'),
              ),
              ButtonSegment<WidgetTabs>(
                value: WidgetTabs.both,
                label: Text('Both'),
              ),
            ],
            selected: <WidgetTabs>{prefs.tabs},
            onSelectionChanged: prefs.enabled
                ? (Set<WidgetTabs> selection) =>
                      unawaited(update(prefs.copyWith(tabs: selection.first)))
                : null,
          ),
        ),
        if (prefs.alwaysOnTop && !widgetState.alwaysOnTopHonored)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ForgeSpacing.md,
              ForgeSpacing.xs,
              ForgeSpacing.md,
              0,
            ),
            child: Text(
              'Note: this desktop session (Wayland) may not keep the widget '
              'pinned above other windows.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(ForgeSpacing.md),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.open_in_new),
              label: const Text('Show widget now'),
              onPressed: prefs.enabled
                  ? () => unawaited(controller.enterWidgetMode())
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}

/// A start-on-login switch that reconciles its displayed value with the OS
/// registration on first build so it reflects reality, not just the stored
/// preference.
class _AutostartTile extends ConsumerStatefulWidget {
  const _AutostartTile({
    required this.startOnLogin,
    required this.enabled,
    required this.onChanged,
  });

  final bool startOnLogin;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  ConsumerState<_AutostartTile> createState() => _AutostartTileState();
}

class _AutostartTileState extends ConsumerState<_AutostartTile> {
  bool? _osEnabled;

  @override
  void initState() {
    super.initState();
    unawaited(_reconcile());
  }

  Future<void> _reconcile() async {
    final bool value = await ref.read(autostartControllerProvider).isEnabled();
    if (mounted) {
      setState(() => _osEnabled = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool value = _osEnabled ?? widget.startOnLogin;
    return SwitchListTile(
      value: value,
      title: const Text('Start Forge at login'),
      subtitle: const Text('Launch automatically when you sign in.'),
      onChanged: widget.enabled
          ? (bool next) {
              setState(() => _osEnabled = next);
              widget.onChanged(next);
            }
          : null,
    );
  }
}
