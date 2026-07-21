import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/backup/application/recovery_center.dart';
import 'package:forge/features/backup/presentation/backup_providers.dart';
import 'package:forge/features/backup/presentation/recovery_center_page.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// A pure in-memory [RecoveryCenter] so the routed surface can be driven
/// without any filesystem, crypto, or database. Restore never touches real
/// state; it only records what it was asked to do.
final class _FakeRecoveryCenter implements RecoveryCenter {
  _FakeRecoveryCenter(this._points);

  final List<RecoveryPoint> _points;

  RecoveryPoint? restoredPoint;
  List<int>? restoredPassphrase;

  @override
  Future<List<RecoveryPoint>> listRecoveryPoints() async => _points;

  @override
  Future<RecoveryRestoreOutcome> restore({
    required RecoveryPoint point,
    required List<int> passphrase,
  }) async {
    restoredPoint = point;
    restoredPassphrase = passphrase;
    return const RecoveryRestoreOutcome(
      recoveredCommitSeq: 9,
      schemaVersion: 1,
      rolledBack: false,
    );
  }
}

void main() {
  List<RecoveryPoint> samplePoints() => const <RecoveryPoint>[
    RecoveryPoint(
      id: 'backup-a.fbc1',
      label: 'backup-a.fbc1',
      source: RecoverySource.userBackup,
      sizeBytes: 2048,
    ),
  ];

  Future<void> pump(WidgetTester tester, {RecoveryCenter? center}) =>
      tester.pumpWidget(
        ProviderScope(
          overrides: [
            if (center != null)
              recoveryCenterProvider.overrideWithValue(center),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const RecoveryCenterPage(),
          ),
        ),
      );

  testWidgets('shows the honest empty state when the seam is unwired', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('No recovery points found'), findsOneWidget);
  });

  testWidgets('lists discovered recovery points from the port', (
    WidgetTester tester,
  ) async {
    await pump(tester, center: _FakeRecoveryCenter(samplePoints()));
    await tester.pumpAndSettle();
    expect(find.text('backup-a.fbc1'), findsOneWidget);
    expect(find.text('Restore'), findsOneWidget);
  });

  testWidgets('restore prompts for a passphrase and drives the port', (
    WidgetTester tester,
  ) async {
    final _FakeRecoveryCenter fake = _FakeRecoveryCenter(samplePoints());
    await pump(tester, center: fake);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    // The passphrase dialog is shown; nothing has been restored yet.
    expect(find.text('Enter backup passphrase'), findsOneWidget);
    expect(fake.restoredPoint, isNull);

    await tester.enterText(find.byType(TextField), 'correct horse battery');
    // Confirm via the dialog's Restore action (scoped to the AlertDialog so it
    // is not confused with the recovery-point tile's own Restore button).
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Restore'),
      ),
    );
    await tester.pumpAndSettle();

    expect(fake.restoredPoint?.id, 'backup-a.fbc1');
    expect(fake.restoredPassphrase, utf8.encode('correct horse battery'));
    expect(find.textContaining('Restore complete'), findsOneWidget);
  });

  testWidgets('cancelling the passphrase prompt touches nothing', (
    WidgetTester tester,
  ) async {
    final _FakeRecoveryCenter fake = _FakeRecoveryCenter(samplePoints());
    await pump(tester, center: fake);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(fake.restoredPoint, isNull);
  });
}
