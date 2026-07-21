import 'package:flutter/material.dart';
import 'package:forge/app/composition_root.dart';
import 'package:forge/app/routing/app_router.dart';
import 'package:forge/config/app_config.dart';
import 'package:forge/core/ui/forge_theme.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

final class ForgeApp extends StatefulWidget {
  const ForgeApp({required this.config, this.router, super.key});

  final AppConfig config;
  final GoRouter? router;

  @override
  State<ForgeApp> createState() => _ForgeAppState();
}

final class _ForgeAppState extends State<ForgeApp> {
  late GoRouter _router;
  late bool _ownsRouter;

  @override
  void initState() {
    super.initState();
    _setRouter(widget.router);
  }

  @override
  void didUpdateWidget(covariant ForgeApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.router != widget.router) {
      if (_ownsRouter) {
        _router.dispose();
      }
      _setRouter(widget.router);
    }
  }

  void _setRouter(GoRouter? router) {
    _ownsRouter = router == null;
    _router = router ?? createForgeRouter();
  }

  @override
  void dispose() {
    if (_ownsRouter) {
      _router.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ForgeCompositionRoot(
      config: widget.config,
      child: MaterialApp.router(
        debugShowCheckedModeBanner:
            widget.config.environment != ForgeEnvironment.production,
        restorationScopeId: 'forgeApp',
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        onGenerateTitle: (BuildContext context) =>
            AppLocalizations.of(context).appName,
        theme: ForgeTheme.light(),
        darkTheme: ForgeTheme.dark(),
        highContrastTheme: ForgeTheme.light(highContrast: true),
        highContrastDarkTheme: ForgeTheme.dark(highContrast: true),
        themeMode: ThemeMode.system,
        routerConfig: _router,
      ),
    );
  }
}
