import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/backup/application/recovery_center.dart';
import 'package:forge/features/backup/presentation/recovery_center_screen.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

void main() {
  List<RecoveryPoint> samplePoints() => const <RecoveryPoint>[
    RecoveryPoint(
      id: 'backup-a.fbc1',
      label: 'backup-a.fbc1',
      source: RecoverySource.userBackup,
      sizeBytes: 2048,
      capturedAtUtcMicros: 1730000000000000,
    ),
    RecoveryPoint(
      id: 'safety.fbc1',
      label: 'safety.fbc1',
      source: RecoverySource.safetyBackup,
      sizeBytes: 4096,
    ),
  ];

  Future<void> pump(
    WidgetTester tester, {
    required List<RecoveryPoint> points,
    required void Function(RecoveryPoint) onRestore,
    RecoveryCenterStatus status = RecoveryCenterStatus.idle,
    String? busyPointId,
  }) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RecoveryCenterScreen(
        points: points,
        onRestore: onRestore,
        status: status,
        busyPointId: busyPointId,
      ),
    ),
  );

  testWidgets('lists recovery points with honest source labels', (
    WidgetTester tester,
  ) async {
    await pump(tester, points: samplePoints(), onRestore: (_) {});
    expect(find.text('Recovery center'), findsOneWidget);
    expect(find.text('backup-a.fbc1'), findsOneWidget);
    expect(find.text('safety.fbc1'), findsOneWidget);
    expect(find.textContaining('Backup you saved'), findsOneWidget);
    expect(find.textContaining('Automatic safety backup'), findsOneWidget);
    // Reassurance that the current data stays active is present.
    expect(find.textContaining('current data stays active'), findsOneWidget);
  });

  testWidgets('empty state explains what to do without blanking', (
    WidgetTester tester,
  ) async {
    await pump(tester, points: const <RecoveryPoint>[], onRestore: (_) {});
    expect(find.textContaining('No recovery points found'), findsOneWidget);
  });

  testWidgets('tapping restore invokes the callback with the point', (
    WidgetTester tester,
  ) async {
    RecoveryPoint? restored;
    await pump(
      tester,
      points: samplePoints(),
      onRestore: (RecoveryPoint p) => restored = p,
    );
    await tester.tap(find.text('Restore').first);
    await tester.pump();
    expect(restored, isNotNull);
    expect(restored!.id, 'backup-a.fbc1');
  });

  testWidgets('restore controls are disabled and progress shows while busy', (
    WidgetTester tester,
  ) async {
    RecoveryPoint? restored;
    await pump(
      tester,
      points: samplePoints(),
      onRestore: (RecoveryPoint p) => restored = p,
      status: RecoveryCenterStatus.restoring,
      busyPointId: 'backup-a.fbc1',
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('Restoring and verifying'), findsOneWidget);
    await tester.tap(find.text('Restore').first, warnIfMissed: false);
    await tester.pump();
    expect(restored, isNull);
  });

  testWidgets('the failed banner reassures data is unchanged', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      points: samplePoints(),
      onRestore: (_) {},
      status: RecoveryCenterStatus.failed,
    );
    expect(find.textContaining('current data is unchanged'), findsOneWidget);
  });

  testWidgets('meets accessibility guidelines (labels, contrast, tap size)', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await pump(tester, points: samplePoints(), onRestore: (_) {});
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    handle.dispose();
  });
}
