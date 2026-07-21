// Minimal on-device/emulator smoke test (mobile platform gate).
//
// Boots the REAL production app via `main()` — which opens the encrypted
// database, wires every feature service, and (on mobile) composes the three
// platform adapters behind their existing ports (home-screen widgets over
// `home_widget`, biometric app-lock over `local_auth`, and share-intent capture
// over `receive_sharing_intent`) — and asserts it reaches the Today surface
// without throwing. It deliberately does NOT drive interactive widget/biometric
// flows; the gate is that the APK boots to Today and the adapters initialize.
//
// Bootstrap is asynchronous and the loading state shows an infinite spinner, so
// `pumpAndSettle` cannot be used (it would never settle). Instead this pumps in
// a bounded loop until the Today screen mounts.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/home/presentation/today_screen.dart';
import 'package:forge/main.dart' as app;
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app launches to Today with mobile adapters wired', (
    WidgetTester tester,
  ) async {
    await app.main();

    // Bootstrap (encrypted DB open + key vault + feature wiring) resolves
    // asynchronously. Pump in a bounded loop until the Today surface appears.
    final Finder today = find.byType(TodayScreen);
    const Duration step = Duration(milliseconds: 250);
    const int maxSteps = 160; // ~40s ceiling for a cold boot on an emulator.
    var found = false;
    for (var i = 0; i < maxSteps; i++) {
      await tester.pump(step);
      if (today.evaluate().isNotEmpty) {
        found = true;
        break;
      }
    }

    expect(
      found,
      isTrue,
      reason:
          'Expected the Today screen to mount after bootstrap. If this '
          'fails the app likely fell back to Recovery Mode or is still '
          'bootstrapping.',
    );

    // The app rendered a live Material surface (not a crash/blank).
    expect(find.byType(MaterialApp), findsWidgets);
  });
}
