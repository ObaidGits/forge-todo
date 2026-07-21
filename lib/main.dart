import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/bootstrap.dart';
import 'package:forge/app/composition_root.dart';
// Desktop "sticky widget" shell (Linux + Windows). Imported unconditionally
// (the plugin Dart APIs compile on every platform), but every use is guarded by
// [_isDesktopPlatform] so Android/iOS builds and behavior are unaffected.
import 'package:forge/app/desktop/autostart_controller.dart';
import 'package:forge/app/desktop/close_behavior.dart';
import 'package:forge/app/desktop/desktop_bindings.dart';
import 'package:forge/app/desktop/desktop_providers.dart';
import 'package:forge/app/desktop/desktop_settings_store.dart';
import 'package:forge/app/desktop/desktop_shell_binder.dart';
import 'package:forge/app/desktop/desktop_window_manager.dart';
import 'package:forge/app/desktop/window_state.dart';
import 'package:forge/app/infrastructure/database/recovery_mode.dart';
import 'package:forge/app/infrastructure/security/local_auth_biometric_authenticator.dart';
import 'package:forge/config/app_config.dart';
import 'package:forge/core/security/app_lock.dart';
import 'package:forge/core/ui/forge_theme.dart';
import 'package:forge/features/areas/presentation/area_providers.dart';
import 'package:forge/features/backup/presentation/backup_providers.dart';
import 'package:forge/features/fitness/presentation/fitness_providers.dart';
import 'package:forge/features/focus/presentation/focus_providers.dart';
import 'package:forge/features/goals/presentation/goal_providers.dart';
import 'package:forge/features/habits/presentation/habit_providers.dart';
import 'package:forge/features/home/infrastructure/share_intent_capture_port.dart';
import 'package:forge/features/home/presentation/home_providers.dart';
import 'package:forge/features/home/presentation/inbound_capture_providers.dart';
import 'package:forge/features/insights/presentation/insights_providers.dart';
import 'package:forge/features/learning/presentation/learning_providers.dart';
import 'package:forge/features/notes/presentation/note_providers.dart';
import 'package:forge/features/notifications/domain/reminder_reconciliation.dart';
import 'package:forge/features/planner/presentation/planner_providers.dart';
import 'package:forge/features/search/presentation/search_providers.dart';
import 'package:forge/features/security/presentation/app_lock_providers.dart';
import 'package:forge/features/security/presentation/recovery_mode_screen.dart';
import 'package:forge/features/sync/presentation/sync_providers.dart';
import 'package:forge/features/tasks/presentation/task_providers.dart';
import 'package:forge/features/widgets/application/forge_widget_bridge.dart';
import 'package:forge/features/widgets/application/widget_bridge.dart';
import 'package:forge/features/widgets/application/widget_intent_verifier.dart';
import 'package:forge/features/widgets/application/widget_publisher.dart';
import 'package:forge/features/widgets/application/widget_snapshot_builder.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_host.dart';
import 'package:forge/features/widgets/infrastructure/habit_widget_command_handler.dart';
import 'package:forge/features/widgets/infrastructure/home_widget_host_channel.dart';
import 'package:forge/features/widgets/infrastructure/in_memory_widget_snapshot_store.dart';
import 'package:forge/features/widgets/infrastructure/keyed_hash_widget_intent_signer.dart';
import 'package:forge/features/widgets/infrastructure/task_widget_command_handler.dart';
import 'package:forge/features/widgets/presentation/widget_providers.dart';
import 'package:forge/forge_app.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// True on the desktop targets Forge's sticky widget supports (Windows + Linux;
/// macOS included for completeness). Never true on Android/iOS or web.
bool get _isDesktopPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Desktop-only: bring up the frameless-capable window and autostart launcher
  // before the first frame. Guarded so mobile is entirely unaffected.
  if (_isDesktopPlatform) {
    try {
      await initializeDesktopWindowManager();
      LaunchAtStartupAutostartController.setup();
    } on Object catch (error) {
      debugPrint('[forge.desktop] window init skipped: $error');
    }
  }
  final AppConfig config = AppConfig.fromEnvironment();
  runApp(ForgeBootstrap(config: config));
}

/// Owns the asynchronous production bootstrap: it opens the encrypted database,
/// wires feature services, and swaps in either the wired app, the Recovery-Mode
/// surface, or a calm loading indicator (design.md §6, R-SEC-001).
final class ForgeBootstrap extends StatefulWidget {
  const ForgeBootstrap({required this.config, super.key});

  final AppConfig config;

  @override
  State<ForgeBootstrap> createState() => _ForgeBootstrapState();
}

class _ForgeBootstrapState extends State<ForgeBootstrap> {
  late Future<BootstrapResult> _bootstrap;

  @override
  void initState() {
    super.initState();
    _bootstrap = bootstrapForge(config: widget.config);
  }

  void _retry() {
    setState(() {
      _bootstrap = bootstrapForge(config: widget.config);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<BootstrapResult>(
      future: _bootstrap,
      builder: (BuildContext context, AsyncSnapshot<BootstrapResult> snapshot) {
        if (snapshot.hasError) {
          return _ShellApp(
            config: widget.config,
            child: RecoveryModeScreen(
              info: const RecoveryModeInfo(reason: RecoveryReason.openFailed),
              onRetry: _retry,
            ),
          );
        }
        final BootstrapResult? result = snapshot.data;
        if (result == null) {
          return _ShellApp(
            config: widget.config,
            child: const _BootstrapLoading(),
          );
        }
        return switch (result) {
          BootstrapReady() => _WiredApp(config: widget.config, ready: result),
          BootstrapRecovery(:final info) => _ShellApp(
            config: widget.config,
            child: RecoveryModeScreen(info: info, onRetry: _retry),
          ),
        };
      },
    );
  }
}

/// The wired application: a ProviderScope that overrides the encrypted runtime
/// factory and every Home composition seam with the constructed feature
/// services, then hosts [ForgeApp] (design.md §6, R-HOME-001..005).
///
/// It also drives the R-NOTIFY-004 lifecycle triggers for real OS reminders:
/// it reconciles the rolling horizon once on launch and again on every app
/// resume. Reconciliation is best-effort and fire-and-forget — offline, a
/// missing notification daemon, or denied permission degrade to visible
/// diagnostics (recorded on reminder rows) and never block or crash the UI.
final class _WiredApp extends StatefulWidget {
  const _WiredApp({required this.config, required this.ready});

  final AppConfig config;
  final BootstrapReady ready;

  @override
  State<_WiredApp> createState() => _WiredAppState();
}

class _WiredAppState extends State<_WiredApp> with WidgetsBindingObserver {
  /// Mobile-only platform integration (home-screen widgets, biometric app-lock,
  /// share-intent capture). Null on desktop so those builds are unaffected.
  _MobileIntegration? _mobile;

  /// Desktop-only sticky-widget integration (frameless widget mode, tray,
  /// global hotkey, autostart). Null on mobile so those builds are unaffected.
  _DesktopIntegration? _desktop;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Compose the mobile platform adapters behind their existing ports. Guarded
    // by platform so desktop/Linux is entirely unaffected; a missing capability
    // degrades gracefully and never blocks the local-first app.
    if (_isMobilePlatform) {
      _mobile = _MobileIntegration.build(widget.ready);
      _mobile?.onLaunch();
    }
    // Compose the desktop sticky-widget shell behind its existing desktop ports.
    // Guarded so Android/iOS is entirely unaffected.
    if (_isDesktopPlatform) {
      _desktop = _DesktopIntegration.build();
    }
    // Launch trigger: reconcile once the first frame is scheduled so bootstrap
    // completion never waits on the OS scheduler (R-NOTIFY-004).
    _triggerReconcile(ReconciliationTrigger.launch);
  }

  @override
  void dispose() {
    _mobile?.dispose();
    _desktop?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Resume trigger: the horizon may have shifted (time passed, timezone or
      // permission changed) while backgrounded (R-NOTIFY-004).
      _triggerReconcile(ReconciliationTrigger.resume);
      // Refresh the home-screen widget surfaces from the latest local state.
      _mobile?.onResume();
    }
  }

  static bool get _isMobilePlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Fire-and-forget reconciliation. Errors are swallowed here because the
  /// service already maps OS/transport failures to diagnostics on reminder
  /// rows; a launch/resume reconcile must never surface as an unhandled error.
  void _triggerReconcile(ReconciliationTrigger trigger) {
    unawaited(
      widget.ready.reminderService
          .reconcile(widget.ready.profileId.value, trigger)
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final BootstrapReady ready = widget.ready;
    final AppConfig config = widget.config;
    return ProviderScope(
      overrides: [
        databaseRuntimeFactoryProvider.overrideWithValue(ready.runtimeFactory),
        activeProfileProvider.overrideWithValue(ready.profileId),
        quickCaptureAreaProvider.overrideWithValue(ready.quickCaptureAreaId),
        homeClockProvider.overrideWithValue(ready.clock),
        homeLayoutStoreProvider.overrideWithValue(ready.layoutStore),
        taskQueryServiceProvider.overrideWithValue(ready.taskQuery),
        taskCommandServiceProvider.overrideWithValue(ready.taskCommands),
        learningResumeContractProvider.overrideWithValue(ready.learningResume),
        homeHabitQueryServiceProvider.overrideWithValue(ready.habitQuery),
        homeHabitCommandServiceProvider.overrideWithValue(ready.habitCommands),
        homeFocusContractProvider.overrideWithValue(ready.focusContract),
        homeFocusCommandServiceProvider.overrideWithValue(ready.focusCommands),

        // Focus tab (R-FOCUS-*): active-session read + durable commands.
        focusProfileProvider.overrideWithValue(ready.profileId),
        focusContractProvider.overrideWithValue(ready.focusContract),
        focusSessionReadProvider.overrideWithValue(ready.focusSessionRead),
        focusCommandServiceProvider.overrideWithValue(ready.focusCommands),
        focusClockProvider.overrideWithValue(ready.clock),
        focusDefaultAreaProvider.overrideWithValue(ready.quickCaptureAreaId),

        // Tasks tab (R-TASK-*): list, detail, recurrence, trash + purge.
        tasksProfileProvider.overrideWithValue(ready.profileId),
        tasksQueryServiceProvider.overrideWithValue(ready.taskQuery),
        tasksCommandServiceProvider.overrideWithValue(ready.taskCommands),
        tasksRecurrenceServiceProvider.overrideWithValue(ready.taskRecurrence),
        tasksDeletionServiceProvider.overrideWithValue(ready.taskDeletion),
        tasksPurgePreviewServiceProvider.overrideWithValue(
          ready.taskPurgePreview,
        ),
        tasksClockProvider.overrideWithValue(ready.clock),
        tasksDefaultAreaProvider.overrideWithValue(ready.quickCaptureAreaId),

        // Goals tab (R-GOAL-*): goals + roadmap read/write.
        goalsProfileProvider.overrideWithValue(ready.profileId),
        goalsRepositoryProvider.overrideWithValue(ready.goalRepository),
        roadmapRepositoryProvider.overrideWithValue(ready.roadmapRepository),
        goalsCommandServiceProvider.overrideWithValue(ready.goalCommands),
        roadmapCommandServiceProvider.overrideWithValue(ready.roadmapCommands),
        goalsDefaultAreaProvider.overrideWithValue(ready.quickCaptureAreaId),

        // Notes tab (R-NOTE-*): read, commands, trash. The draft journal seam
        // stays at its safe default when unwired (no production draft cipher).
        notesProfileProvider.overrideWithValue(ready.profileId),
        notesRepositoryProvider.overrideWithValue(ready.noteRepository),
        notesCommandServiceProvider.overrideWithValue(ready.noteCommands),
        notesDeletionServiceProvider.overrideWithValue(ready.noteDeletion),
        if (ready.noteDraftJournal != null)
          notesDraftJournalProvider.overrideWithValue(ready.noteDraftJournal),
        notesClockProvider.overrideWithValue(ready.clock),
        notesDefaultAreaProvider.overrideWithValue(ready.quickCaptureAreaId),

        // Learn tab (R-LEARN-*): resource read + durable commands.
        learningProfileProvider.overrideWithValue(ready.profileId),
        learningRepositoryProvider.overrideWithValue(ready.learningRepository),
        learningCommandServiceProvider.overrideWithValue(
          ready.learningCommands,
        ),
        learningClockProvider.overrideWithValue(ready.clock),
        learningDefaultAreaProvider.overrideWithValue(ready.quickCaptureAreaId),

        // Planner tab (R-PLAN-*): daily record read + durable commands.
        plannerProfileProvider.overrideWithValue(ready.profileId),
        plannerRepositoryProvider.overrideWithValue(ready.plannerRepository),
        plannerCommandServiceProvider.overrideWithValue(ready.plannerCommands),
        plannerClockProvider.overrideWithValue(ready.clock),
        plannerDefaultAreaProvider.overrideWithValue(ready.quickCaptureAreaId),

        // Habits tab (R-HABIT-*): reuses the Today-wired habit services.
        habitsProfileProvider.overrideWithValue(ready.profileId),
        habitsQueryServiceProvider.overrideWithValue(ready.habitQuery),
        habitsCommandServiceProvider.overrideWithValue(ready.habitCommands),
        habitsClockProvider.overrideWithValue(ready.clock),

        // Search tab (R-SEARCH-*): unified search + saved filters.
        searchProfileProvider.overrideWithValue(ready.profileId),
        searchServiceProvider.overrideWithValue(ready.searchService),
        savedFiltersStoreProvider.overrideWithValue(ready.savedFilters),

        // Life Areas tab (R-GEN-002): query + command services.
        areasProfileProvider.overrideWithValue(ready.profileId),
        lifeAreaQueryServiceProvider.overrideWithValue(ready.areaQuery),
        lifeAreaCommandServiceProvider.overrideWithValue(ready.areaCommands),

        // Fitness screen (R-FIT-*): reached from Settings (no nav-rail tab).
        // Read + durable commands; water tracking stays off by default.
        fitnessProfileProvider.overrideWithValue(ready.profileId),
        fitnessQueryServiceProvider.overrideWithValue(ready.fitnessQuery),
        fitnessCommandServiceProvider.overrideWithValue(ready.fitnessCommands),
        fitnessClockProvider.overrideWithValue(ready.clock),
        fitnessDefaultAreaProvider.overrideWithValue(ready.quickCaptureAreaId),

        // Insights screen (R-INSIGHT-*): reached from Settings (no nav-rail
        // tab). Weekly/monthly comparisons computed from the local factual
        // closes, scoped to the default Life Area.
        insightsProfileProvider.overrideWithValue(ready.profileId),
        insightsServiceProvider.overrideWithValue(ready.insightsService),
        insightsClockProvider.overrideWithValue(ready.clock),
        insightsLifeAreaProvider.overrideWithValue(ready.quickCaptureAreaId),

        // Recovery Center (R-BACKUP-003, R-BACKUP-004): reached from Settings
        // (no nav-rail tab). The seam stays at its safe default when unwired
        // (no production FBC1 backend in this build), so the surface shows an
        // honest empty state; restore always goes through the existing
        // non-destructive staged generation restore.
        if (ready.recoveryCenter != null)
          recoveryCenterProvider.overrideWithValue(ready.recoveryCenter),

        // Optional cloud sync (R-SYNC-001/005/007): the "Account & sync"
        // surface and its Settings tile appear only when a backend is
        // configured, so the default local-first build is unchanged.
        if (ready.syncService != null)
          supabaseSyncServiceProvider.overrideWithValue(ready.syncService),

        // Mobile platform capabilities (Android/iOS only): home-screen widgets,
        // biometric app-lock, and share-intent capture — each behind its
        // existing port so desktop is unaffected.
        if (_mobile != null)
          appLockGateProvider.overrideWithValue(_mobile!.lockGate),
        if (_mobile != null)
          biometricAuthenticatorProvider.overrideWithValue(_mobile!.biometric),
        if (_mobile != null)
          inboundCapturePortProvider.overrideWithValue(_mobile!.sharePort),
        if (_mobile != null)
          widgetBridgeProvider.overrideWithValue(_mobile!.widgetBridge),
        if (_mobile != null)
          widgetPublisherProvider.overrideWithValue(_mobile!.widgetPublisher),

        // Desktop sticky-widget platform bindings (Windows/Linux/macOS only):
        // real window manager, tray, autostart, and a durable local settings
        // store — each behind its existing desktop port so mobile is unaffected.
        if (_desktop != null)
          desktopSettingsStoreProvider.overrideWithValue(_desktop!.settings),
        if (_desktop != null)
          windowControllerProvider.overrideWithValue(
            _desktop!.windowController,
          ),
        if (_desktop != null)
          desktopWindowManagerProvider.overrideWithValue(
            _desktop!.windowManager,
          ),
        if (_desktop != null)
          trayControllerProvider.overrideWithValue(_desktop!.tray),
        if (_desktop != null)
          autostartControllerProvider.overrideWithValue(_desktop!.autostart),
      ],
      child: _desktop == null
          ? ForgeApp(config: config)
          : DesktopShellBinder(
              shell: _desktop!.shell,
              child: DesktopWidgetHost(fullApp: ForgeApp(config: config)),
            ),
    );
  }
}

/// The composed mobile-only platform integration: the three additive adapters
/// wired behind the app's existing ports (R-WIDGET-002/003/004, R-SEC-003,
/// R-SEARCH-004). Constructed once per wired session and torn down on dispose.
///
/// Everything here is defensive: a device with no widget host, no biometric
/// hardware, or no share source degrades gracefully and never crashes or blocks
/// the local-first app.
final class _MobileIntegration {
  _MobileIntegration._({
    required this.ready,
    required this.lockGate,
    required this.biometric,
    required this.sharePort,
    required this.widgetChannel,
    required this.widgetBridge,
    required this.widgetPublisher,
    required this.widgetSecret,
  });

  factory _MobileIntegration.build(BootstrapReady ready) {
    // Presentation/session lock gate (R-SEC-003). Shared across the biometric
    // controller, inbound-capture gating, and the widget publisher's redaction.
    final AppLockGate lockGate = AppLockGate(elapsed: () => Duration.zero);

    // (1) Biometric app-lock capability over `local_auth`, behind the
    //     BiometricAuthenticator port.
    final LocalAuthBiometricAuthenticator biometric =
        LocalAuthBiometricAuthenticator();

    // (2) Share-intent capture over `receive_sharing_intent`, behind the
    //     InboundCapturePort.
    final ShareIntentCapturePort sharePort = ShareIntentCapturePort();

    // (3) Home-screen widget bridge over `home_widget`, behind the
    //     WidgetHostChannel / WidgetBridge ports.
    final HomeWidgetHostChannel widgetChannel = const HomeWidgetHostChannel();
    // A deterministic, local-only bridge secret shared with the native signer.
    final String widgetSecret = 'forge-widget-secret-${ready.profileId.value}';
    final KeyedHashWidgetIntentSigner signer = KeyedHashWidgetIntentSigner(
      secret: widgetSecret,
    );
    final ForgeWidgetBridge widgetBridge = ForgeWidgetBridge(
      verifier: WidgetIntentVerifier(
        signer: signer,
        clock: ready.clock,
        activeProfileId: ready.profileId,
      ),
      handlers: <WidgetCommandHandler>[
        TaskWidgetCommandHandler(ready.taskCommands),
        HabitWidgetCommandHandler(ready.habitCommands, ready.clock),
      ],
      channel: widgetChannel,
      snapshots: InMemoryWidgetSnapshotStore(),
    );
    final WidgetPublisher widgetPublisher = WidgetPublisher(
      bridge: widgetBridge,
      builder: WidgetSnapshotBuilder(clock: ready.clock),
      clock: ready.clock,
      taskQuery: ready.taskQuery,
      lock: lockGate,
    );

    return _MobileIntegration._(
      ready: ready,
      lockGate: lockGate,
      biometric: biometric,
      sharePort: sharePort,
      widgetChannel: widgetChannel,
      widgetBridge: widgetBridge,
      widgetPublisher: widgetPublisher,
      widgetSecret: widgetSecret,
    );
  }

  final BootstrapReady ready;
  final AppLockGate lockGate;
  final LocalAuthBiometricAuthenticator biometric;
  final ShareIntentCapturePort sharePort;
  final HomeWidgetHostChannel widgetChannel;
  final ForgeWidgetBridge widgetBridge;
  final WidgetPublisher widgetPublisher;
  final String widgetSecret;

  /// Launch-time initialization: publish the local-only bridge secret so the
  /// native container can authenticate widget taps, then publish an initial
  /// snapshot for every surface. Best-effort and non-throwing.
  void onLaunch() {
    debugPrint(
      '[forge.mobile] mobile adapters initialized: '
      'home_widget bridge, local_auth biometric, share-intent capture',
    );
    unawaited(
      widgetChannel
          .publishSecret(widgetSecret)
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    _publishWidgets();
  }

  /// Resume-time refresh of the widget surfaces.
  void onResume() => _publishWidgets();

  void _publishWidgets() {
    unawaited(
      widgetPublisher
          .publishAll(ready.profileId)
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  void dispose() {
    unawaited(sharePort.dispose());
  }
}

/// The composed desktop-only sticky-widget integration: the concrete
/// `window_manager` / `tray_manager` / `launch_at_startup` adapters behind the
/// app's existing desktop ports, plus a durable local settings store and the
/// [DesktopShell] that owns the tray, global hotkey, and window-close listener.
///
/// Constructed once per wired session on desktop and torn down on dispose.
/// Everything is defensive: a headless session, a missing tray host, or a
/// compositor that ignores always-on-top degrades gracefully and never crashes
/// or blocks the single-engine app.
final class _DesktopIntegration {
  _DesktopIntegration._({
    required this.settings,
    required this.windowController,
    required this.windowManager,
    required this.tray,
    required this.autostart,
    required this.shell,
  });

  factory _DesktopIntegration.build() {
    // A durable, device-local settings file under the same app-support base as
    // the encrypted database (never synced; R-SYNC-002 local-only class).
    final DesktopSettingsStore settings = FileDesktopSettingsStore(
      io.File(
        '${_desktopAppSupportDirectory()}${io.Platform.pathSeparator}'
        'desktop_settings.json',
      ),
    );
    return _DesktopIntegration._(
      settings: settings,
      windowController: const WindowManagerWindowController(),
      windowManager: const WindowManagerDesktopWindowManager(),
      tray: const TrayManagerTrayController(),
      autostart: const LaunchAtStartupAutostartController(),
      shell: DesktopShell(hotkeys: HotkeyManagerGlobalHotkeyBinder()),
    );
  }

  final DesktopSettingsStore settings;
  final WindowController windowController;
  final DesktopWindowManager windowManager;
  final TrayController tray;
  final AutostartController autostart;
  final DesktopShell shell;

  void dispose() {
    unawaited(shell.stop());
  }
}

/// Resolves the per-OS application-support directory for desktop, mirroring the
/// dependency-free environment lookup the bootstrap uses for the encrypted
/// store so desktop preferences live beside the database.
String _desktopAppSupportDirectory() {
  final Map<String, String> env = io.Platform.environment;
  final String sep = io.Platform.pathSeparator;
  String base;
  if (io.Platform.isWindows) {
    base = env['APPDATA'] ?? env['LOCALAPPDATA'] ?? io.Directory.current.path;
  } else if (io.Platform.isMacOS) {
    final String home = env['HOME'] ?? io.Directory.current.path;
    base = '$home${sep}Library${sep}Application Support';
  } else {
    final String? xdg = env['XDG_DATA_HOME'];
    base = (xdg != null && xdg.isNotEmpty)
        ? xdg
        : '${env['HOME'] ?? io.Directory.current.path}$sep.local${sep}share';
  }
  return '$base${sep}forge';
}

/// A minimal localized MaterialApp shell used for the loading and Recovery-Mode
/// surfaces, before the routed shell is available.
final class _ShellApp extends StatelessWidget {
  const _ShellApp({required this.config, required this.child});

  final AppConfig config;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner:
          config.environment != ForgeEnvironment.production,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      onGenerateTitle: (BuildContext context) =>
          AppLocalizations.of(context).appName,
      theme: ForgeTheme.light(),
      darkTheme: ForgeTheme.dark(),
      highContrastTheme: ForgeTheme.light(highContrast: true),
      highContrastDarkTheme: ForgeTheme.dark(highContrast: true),
      themeMode: ThemeMode.system,
      home: child,
    );
  }
}

final class _BootstrapLoading extends StatelessWidget {
  const _BootstrapLoading();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator.adaptive()),
    );
  }
}
