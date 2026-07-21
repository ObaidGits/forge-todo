import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/desktop/desktop_providers.dart';
import 'package:forge/core/ui/forge_theme.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_controller.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_view.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Hosts the full app and the compact desktop widget within the SAME window and
/// engine (task architecture constraint).
///
/// There is exactly one Flutter engine, so both surfaces share the one
/// [ProviderScope] and therefore the one encrypted DatabaseRuntime — the writer
/// lock is never contended. The full app stays mounted (offstage) while the
/// sticky widget is shown, so returning to full mode is instant and preserves
/// navigation/session state.
final class DesktopWidgetHost extends ConsumerWidget {
  const DesktopWidgetHost({required this.fullApp, super.key});

  final Widget fullApp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DesktopWidgetMode mode = ref.watch(
      desktopWidgetControllerProvider.select((DesktopWidgetState s) => s.mode),
    );
    final bool widgetMode = mode == DesktopWidgetMode.widget;
    // This Stack sits at the very top of the desktop widget tree — above the
    // child MaterialApps that each establish their own Directionality. A bare
    // Stack defaults to AlignmentDirectional.topStart, which needs an ambient
    // TextDirection and throws a null-check at first-frame layout when there is
    // none here. Both children are full-bleed apps, so a non-directional
    // alignment is visually identical and keeps the host free of any ambient
    // Directionality requirement.
    return Stack(
      alignment: Alignment.topLeft,
      children: <Widget>[
        Offstage(offstage: widgetMode, child: fullApp),
        if (widgetMode) const _DesktopWidgetApp(),
      ],
    );
  }
}

/// The compact widget's own themed, localized [MaterialApp] surface.
class _DesktopWidgetApp extends StatelessWidget {
  const _DesktopWidgetApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ForgeTheme.light(),
      darkTheme: ForgeTheme.dark(),
      highContrastTheme: ForgeTheme.light(highContrast: true),
      highContrastDarkTheme: ForgeTheme.dark(highContrast: true),
      themeMode: ThemeMode.system,
      home: const Scaffold(body: DesktopWidgetView()),
    );
  }
}
