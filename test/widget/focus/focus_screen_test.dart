import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/focus/application/focus_command_service.dart';
import 'package:forge/features/focus/application/focus_commands.dart';
import 'package:forge/features/focus/application/focus_today_contract.dart';
import 'package:forge/features/focus/domain/focus_mode.dart';
import 'package:forge/features/focus/presentation/focus_providers.dart';
import 'package:forge/features/focus/presentation/focus_screen.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Widget, semantics and interaction tests for the Focus screen.
///
/// **Validates: Requirements R-FOCUS-001, R-FOCUS-002, R-FOCUS-003,
/// R-FOCUS-004, R-FOCUS-006, NFR-A11Y-001, NFR-A11Y-002, NFR-A11Y-003**
void main() {
  // A controllable, non-ticking cosmetic ticker so pumpAndSettle settles.
  final tickerOverride = focusTickerProvider.overrideWith(
    (Ref ref) => const Stream<int>.empty(),
  );

  MaterialApp app() => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const Scaffold(body: FocusScreen()),
  );

  // Not wired: no profile / command service, so the screen is unavailable.
  Widget unwired() => ProviderScope(overrides: [tickerOverride], child: app());

  Widget wiredHost(_FakeFocus fake) => ProviderScope(
    overrides: [
      tickerOverride,
      focusProfileProvider.overrideWithValue(ProfileId('p1')),
      focusContractProvider.overrideWithValue(fake),
      focusCommandServiceProvider.overrideWithValue(fake),
      focusDefaultAreaProvider.overrideWithValue(LifeAreaId('area1')),
      focusClockProvider.overrideWithValue(_FixedClock()),
    ],
    child: app(),
  );

  testWidgets('shows a calm unavailable state when the stack is not wired', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(unwired());
    await tester.pumpAndSettle();

    expect(find.text("Focus isn't available yet"), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('no active session shows the start presets (R-FOCUS-004)', (
    WidgetTester tester,
  ) async {
    final _FakeFocus fake = _FakeFocus();
    await tester.pumpWidget(wiredHost(fake));
    await tester.pumpAndSettle();

    expect(find.text('Start a focus session'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('focus-start-count-up')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('focus-start-pomodoro')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('focus-start-deep-work')),
      findsOneWidget,
    );
  });

  testWidgets('starting count up opens a running session (R-FOCUS-001)', (
    WidgetTester tester,
  ) async {
    final _FakeFocus fake = _FakeFocus();
    await tester.pumpWidget(wiredHost(fake));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('focus-start-count-up')),
    );
    await tester.pumpAndSettle();

    expect(fake.calls, contains('start'));
    expect(find.text('Running'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('focus-pause')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('focus-end')), findsOneWidget);
  });

  testWidgets('running session can be paused and resumed (R-FOCUS-003)', (
    WidgetTester tester,
  ) async {
    final _FakeFocus fake = _FakeFocus(
      initial: const FocusTodaySnapshot(
        sessionId: 's1',
        statusWire: 'running',
        modeWire: 'count_up',
        accumulatedDurationSec: 65,
      ),
    );
    await tester.pumpWidget(wiredHost(fake));
    await tester.pumpAndSettle();

    // Elapsed derives from the durable accumulated seconds (01:05).
    expect(find.text('01:05'), findsOneWidget);
    expect(find.text('Running'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('focus-pause')));
    await tester.pumpAndSettle();
    expect(fake.calls, contains('pause'));
    expect(find.text('Paused'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('focus-resume')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('focus-resume')));
    await tester.pumpAndSettle();
    expect(fake.calls, contains('resume'));
    expect(find.text('Running'), findsOneWidget);
  });

  testWidgets('ending the session returns to the start area (R-FOCUS-003)', (
    WidgetTester tester,
  ) async {
    final _FakeFocus fake = _FakeFocus(
      initial: const FocusTodaySnapshot(
        sessionId: 's1',
        statusWire: 'running',
        modeWire: 'count_up',
        accumulatedDurationSec: 0,
      ),
    );
    await tester.pumpWidget(wiredHost(fake));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('focus-end')));
    await tester.pumpAndSettle();

    expect(fake.calls, contains('end'));
    expect(find.text('Start a focus session'), findsOneWidget);
  });

  testWidgets('active session meets tap-target and labeling guidelines', (
    WidgetTester tester,
  ) async {
    final _FakeFocus fake = _FakeFocus(
      initial: const FocusTodaySnapshot(
        sessionId: 's1',
        statusWire: 'running',
        modeWire: 'interval',
        accumulatedDurationSec: 0,
        plannedDurationSec: 1500,
      ),
    );
    await tester.pumpWidget(wiredHost(fake));
    await tester.pumpAndSettle();

    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(tester.takeException(), isNull);
  });
}

/// A shared fake standing in for both the read contract and command service so
/// intents mutate the observed active session in place.
final class _FakeFocus implements FocusCommandService, FocusTodayContract {
  _FakeFocus({FocusTodaySnapshot? initial}) : _snapshot = initial;

  FocusTodaySnapshot? _snapshot;
  final List<String> calls = <String>[];

  @override
  Future<FocusTodaySnapshot?> activeSession(
    ProfileId profileId, {
    LifeAreaId? lifeAreaId,
  }) async => _snapshot;

  Success<CommittedCommandResult> _ok(CommandId commandId) =>
      Success<CommittedCommandResult>(
        CommittedCommandResult(
          commandId: commandId,
          resultCode: 'ok',
          payloadVersion: 1,
          commitSeq: 1,
          replayed: false,
        ),
      );

  FocusTodaySnapshot _withStatus(String statusWire) => FocusTodaySnapshot(
    sessionId: _snapshot!.sessionId,
    statusWire: statusWire,
    modeWire: _snapshot!.modeWire,
    accumulatedDurationSec: _snapshot!.accumulatedDurationSec,
    plannedDurationSec: _snapshot!.plannedDurationSec,
    linkLabel: _snapshot!.linkLabel,
  );

  @override
  Future<Result<CommittedCommandResult>> start({
    required CommandId commandId,
    required ProfileId profileId,
    required StartFocusSessionInput input,
  }) async {
    calls.add('start');
    final FocusMode mode =
        input.preset?.mode ?? input.mode ?? FocusMode.countUp;
    _snapshot = FocusTodaySnapshot(
      sessionId: 's1',
      statusWire: 'running',
      modeWire: mode.wire,
      accumulatedDurationSec: 0,
      plannedDurationSec: mode == FocusMode.interval
          ? (input.preset?.plannedDurationSec ?? input.plannedDurationSec)
          : null,
    );
    return _ok(commandId);
  }

  @override
  Future<Result<CommittedCommandResult>> pause({
    required CommandId commandId,
    required ProfileId profileId,
    required PauseFocusSessionInput input,
  }) async {
    calls.add('pause');
    _snapshot = _withStatus('paused');
    return _ok(commandId);
  }

  @override
  Future<Result<CommittedCommandResult>> resume({
    required CommandId commandId,
    required ProfileId profileId,
    required ResumeFocusSessionInput input,
  }) async {
    calls.add('resume');
    _snapshot = _withStatus('running');
    return _ok(commandId);
  }

  @override
  Future<Result<CommittedCommandResult>> end({
    required CommandId commandId,
    required ProfileId profileId,
    required EndFocusSessionInput input,
  }) async {
    calls.add('end');
    _snapshot = null;
    return _ok(commandId);
  }

  @override
  Future<Result<CommittedCommandResult>> cancel({
    required CommandId commandId,
    required ProfileId profileId,
    required CancelFocusSessionInput input,
  }) async {
    calls.add('cancel');
    _snapshot = null;
    return _ok(commandId);
  }

  @override
  Future<Result<CommittedCommandResult>> correct({
    required CommandId commandId,
    required ProfileId profileId,
    required CorrectFocusSessionInput input,
  }) async {
    calls.add('correct');
    return _ok(commandId);
  }
}

final class _FixedClock implements Clock {
  @override
  DateTime utcNow() => DateTime.utc(2024, 6, 15, 12);

  @override
  String timezoneId() => 'UTC';
}
