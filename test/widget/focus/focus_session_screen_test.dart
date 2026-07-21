import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/focus/application/focus_session_read_contract.dart';
import 'package:forge/features/focus/presentation/focus_providers.dart';
import 'package:forge/features/focus/presentation/focus_session_screen.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Widget tests for the read-only focus session detail (`/focus/:sessionId`)
/// (R-FOCUS-002, R-FOCUS-003, NFR-A11Y-001/003).
void main() {
  MaterialApp app(String sessionId) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: FocusSessionScreen(sessionId: sessionId)),
  );

  Widget host(_FakeFocusRead fake, String sessionId) => ProviderScope(
    overrides: [
      focusProfileProvider.overrideWithValue(ProfileId('p1')),
      focusSessionReadProvider.overrideWithValue(fake),
    ],
    child: app(sessionId),
  );

  testWidgets(
    'given_session_when_opened_then_shows_status_mode_and_intervals',
    (WidgetTester tester) async {
      final _FakeFocusRead fake = _FakeFocusRead(
        detail: const FocusSessionDetail(
          sessionId: 's1',
          statusWire: 'completed',
          modeWire: 'interval',
          accumulatedDurationSec: 1500,
          plannedDurationSec: 1500,
          startedAtUtc: 0,
          intervals: <FocusIntervalView>[
            FocusIntervalView(
              kindWire: 'work',
              startedAtUtc: 0,
              endedAtUtc: 1500000000,
            ),
          ],
        ),
      );
      await tester.pumpWidget(host(fake, 's1'));
      await tester.pumpAndSettle();

      expect(find.text('Focus session'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Elapsed'), findsOneWidget);
      // 1500s == 25:00 accumulated.
      expect(find.text('25:00'), findsOneWidget);
      expect(find.text('Intervals'), findsOneWidget);
      expect(find.textContaining('Work'), findsOneWidget);
    },
  );

  testWidgets('given_unknown_session_when_opened_then_shows_not_found', (
    WidgetTester tester,
  ) async {
    final _FakeFocusRead fake = _FakeFocusRead(detail: null);
    await tester.pumpWidget(host(fake, 'missing'));
    await tester.pumpAndSettle();

    expect(find.text('This focus session could not be found.'), findsOneWidget);
  });
}

final class _FakeFocusRead implements FocusSessionReadContract {
  _FakeFocusRead({required this.detail});

  final FocusSessionDetail? detail;

  @override
  Future<FocusSessionDetail?> sessionDetail(
    ProfileId profileId,
    FocusSessionId sessionId,
  ) async => detail;
}
