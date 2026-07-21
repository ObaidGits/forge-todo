import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/routing/app_router.dart';
import 'package:forge/app/routing/uri_policy.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/ui/forge_theme.dart';
import 'package:forge/features/notes/presentation/note_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

import '../../database/notes/note_test_support.dart';

/// Composes the full notes presentation stack over a real encrypted-schema
/// Drift database (via [NoteHarness]) and pumps the real Forge router so
/// `/notes` and `/notes/:noteId` render their production screens.
final class NotesWidgetHarness {
  NotesWidgetHarness._(this.base);

  final NoteHarness base;

  /// Every external URI the (allowlisted, confirmed) launcher was asked to open.
  final List<Uri> launchedExternalUris = <Uri>[];

  /// Controls what the fake OS launcher returns (false simulates a failure).
  bool launcherSucceeds = true;

  static Future<NotesWidgetHarness> open() async {
    final NoteHarness base = await NoteHarness.open();
    return NotesWidgetHarness._(base);
  }

  ProfileId get profileId => base.profileId;

  Future<String> createNote({
    String title = 'A note',
    String body = '',
    bool pinned = false,
  }) => base.createNote(title: title, body: body, pinned: pinned);

  Future<int> scalar(String sql, [List<Object?> args = const <Object?>[]]) =>
      base.scalar(sql, args);

  Future<Map<String, Object?>?> firstRow(
    String sql, [
    List<Object?> args = const <Object?>[],
  ]) => base.firstRow(sql, args);

  Future<void> saveDraft({
    required String noteId,
    required int baseRevision,
    required String body,
    bool markAwaitingRecovery = false,
  }) => base.journal.save(
    profileId: base.profileId,
    noteId: NoteId(noteId),
    baseRevision: baseRevision,
    body: body,
    markAwaitingRecovery: markAwaitingRecovery,
  );

  Future<void> close() => base.close();

  /// Pumps the real router at [initialLocation] with the notes stack wired to
  /// this harness. [externalHosts] seeds the outbound allowlist; [debounce]
  /// controls the autosave window so tests can advance it deterministically.
  Future<void> pumpApp(
    WidgetTester tester, {
    String initialLocation = '/notes',
    Set<String> externalHosts = const <String>{'example.com'},
    Duration debounce = const Duration(milliseconds: 40),
    Size viewport = const Size(1100, 1800),
    ThemeData? theme,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = createForgeRouter(initialLocation: initialLocation);
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notesProfileProvider.overrideWithValue(base.profileId),
          notesRepositoryProvider.overrideWithValue(base.reads),
          notesCommandServiceProvider.overrideWithValue(base.notes),
          notesDraftJournalProvider.overrideWithValue(base.journal),
          notesDeletionServiceProvider.overrideWithValue(base.deletion),
          notesClockProvider.overrideWithValue(base.clock),
          notesCommandIdFactoryProvider.overrideWithValue(base.nextCommandId),
          notesAreaOptionsProvider.overrideWithValue(<NoteAreaOption>[
            NoteAreaOption(id: base.lifeAreaId, name: 'Career'),
          ]),
          notesUriPolicyProvider.overrideWithValue(
            UriPolicy(externalHosts: externalHosts),
          ),
          notesAutosaveDebounceProvider.overrideWithValue(debounce),
          notesLinkLauncherProvider.overrideWithValue((Uri uri) async {
            launchedExternalUris.add(uri);
            return launcherSucceeds;
          }),
        ],
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: theme ?? ForgeTheme.light(),
          routerConfig: router,
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}
