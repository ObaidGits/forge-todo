import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/recovery_mode.dart';
import 'package:forge/features/security/presentation/recovery_mode_screen.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required RecoveryModeInfo info,
    VoidCallback? onRetry,
    VoidCallback? onRestore,
    VoidCallback? onDiagnostics,
  }) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RecoveryModeScreen(
        info: info,
        onRetry: onRetry,
        onRestore: onRestore,
        onDiagnostics: onDiagnostics,
      ),
    ),
  );

  testWidgets('reassures that data is safe and never blanks the screen', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      info: const RecoveryModeInfo(reason: RecoveryReason.keyUnavailable),
    );

    expect(find.text('Forge needs to recover'), findsOneWidget);
    expect(
      find.textContaining('Your data is safe and unchanged'),
      findsOneWidget,
    );
    expect(find.textContaining('unlock your encrypted data'), findsOneWidget);
  });

  testWidgets('each recovery reason maps to distinct plain-language copy', (
    WidgetTester tester,
  ) async {
    final Map<RecoveryReason, String> expected = <RecoveryReason, String>{
      RecoveryReason.keyUnavailable: 'unlock your encrypted data',
      RecoveryReason.pointerCorrupt: 'which version of your data is active',
      RecoveryReason.openFailed: 'could not open your encrypted data',
      RecoveryReason.verificationFailed: 'found a problem while checking',
    };
    for (final MapEntry<RecoveryReason, String> entry in expected.entries) {
      await pump(tester, info: RecoveryModeInfo(reason: entry.key));
      expect(
        find.textContaining(entry.value),
        findsOneWidget,
        reason: 'reason ${entry.key.name}',
      );
    }
  });

  testWidgets('offered actions are wired and keyboard-reachable', (
    WidgetTester tester,
  ) async {
    int retries = 0;
    int restores = 0;
    await pump(
      tester,
      info: const RecoveryModeInfo(
        reason: RecoveryReason.verificationFailed,
        detail: 'integrity_check',
      ),
      onRetry: () => retries += 1,
      onRestore: () => restores += 1,
    );

    expect(find.text('What you can do'), findsOneWidget);
    expect(find.textContaining('integrity_check'), findsOneWidget);

    await tester.tap(find.text('Restore from backup'));
    await tester.tap(find.text('Try opening again'));
    expect(restores, 1);
    expect(retries, 1);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  });

  testWidgets('hides the next-steps section when no actions are provided', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      info: const RecoveryModeInfo(reason: RecoveryReason.openFailed),
    );

    expect(find.text('What you can do'), findsNothing);
    expect(find.text('Forge needs to recover'), findsOneWidget);
  });
}
