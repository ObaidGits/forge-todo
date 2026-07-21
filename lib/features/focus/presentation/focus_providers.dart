import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/focus/application/focus_command_service.dart';
import 'package:forge/features/focus/application/focus_commands.dart';
import 'package:forge/features/focus/application/focus_session_read_contract.dart';
import 'package:forge/features/focus/application/focus_today_contract.dart';
import 'package:forge/features/focus/domain/focus_preset.dart';

// ---------------------------------------------------------------------------
// Composition seams. Defaults keep the running app safe and honest before the
// encrypted runtime is wired; the composition root and tests override them. The
// focus feature owns its own seams so its presentation never imports another
// feature's presentation nor its own infrastructure (design.md §4/§16).
// ---------------------------------------------------------------------------

/// The active local profile, or null when no generation is open yet.
final Provider<ProfileId?> focusProfileProvider = Provider<ProfileId?>(
  (Ref ref) => null,
);

/// The focus feature's exported read contract used to surface the single open
/// session (R-FOCUS-001..003). Null until wired.
final Provider<FocusTodayContract?> focusContractProvider =
    Provider<FocusTodayContract?>((Ref ref) => null);

/// The focus feature's durable command contract (R-FOCUS-001..005). Null until
/// wired.
final Provider<FocusCommandService?> focusCommandServiceProvider =
    Provider<FocusCommandService?>((Ref ref) => null);

/// The focus feature's exported per-session read contract used to render a
/// read-only session detail (R-FOCUS-003). Null until wired.
final Provider<FocusSessionReadContract?> focusSessionReadProvider =
    Provider<FocusSessionReadContract?>((Ref ref) => null);

/// Loads the read-only detail projection for a focus session id. Auto-disposes
/// when the detail route is popped. Returns null when the stack is not wired or
/// the session does not exist.
final focusSessionDetailProvider = FutureProvider.autoDispose
    .family<FocusSessionDetail?, String>((Ref ref, String sessionId) async {
      final ProfileId? profile = ref.watch(focusProfileProvider);
      final FocusSessionReadContract? read = ref.watch(
        focusSessionReadProvider,
      );
      if (profile == null || read == null) {
        return null;
      }
      return read.sessionDetail(profile, FocusSessionId(sessionId));
    });

/// Trusted clock used only to derive the cosmetic running-segment tick from the
/// durable accumulated seconds; persistence stays anchor based (R-FOCUS-002).
final Provider<Clock> focusClockProvider = Provider<Clock>(
  (Ref ref) => const _SystemUtcClock(),
);

/// The Life Area a newly started focus session inherits (R-FOCUS-001). Null when
/// unavailable, in which case starting a session is unavailable.
final Provider<LifeAreaId?> focusDefaultAreaProvider = Provider<LifeAreaId?>(
  (Ref ref) => null,
);

/// Produces a fresh unique [CommandId] per durable command (R-GEN-005).
final Provider<CommandId Function()> focusCommandIdFactoryProvider =
    Provider<CommandId Function()>((Ref ref) => _defaultCommandId);

/// Whether the focus stack is wired at all: a profile plus a command service.
/// Drives the calm empty/unavailable distinction in the UI.
final Provider<bool> focusConfiguredProvider = Provider<bool>((Ref ref) {
  return ref.watch(focusProfileProvider) != null &&
      ref.watch(focusCommandServiceProvider) != null;
});

// ---------------------------------------------------------------------------
// Presentation-safe view of the active session.
// ---------------------------------------------------------------------------

/// A presentation view of the single open focus session, derived from the
/// durable [FocusTodaySnapshot] plus the instant it was observed.
///
/// The displayed elapsed time is a cosmetic projection (R-FOCUS-002): the
/// durable [accumulatedDurationSec] holds whole seconds already completed by
/// closed segments, and while [isRunning] the UI adds the wall time elapsed
/// since [observedAtUtcMicros]. UI ticks are never persisted — pause/resume/end
/// recompute the real accumulated seconds from the timer anchors.
final class FocusSessionView {
  const FocusSessionView({
    required this.sessionId,
    required this.isRunning,
    required this.isPaused,
    required this.modeWire,
    required this.accumulatedDurationSec,
    required this.observedAtUtcMicros,
    this.plannedDurationSec,
    this.linkLabel,
  });

  factory FocusSessionView.fromSnapshot(
    FocusTodaySnapshot snapshot,
    DateTime observedAtUtc,
  ) => FocusSessionView(
    sessionId: snapshot.sessionId,
    isRunning: snapshot.isRunning,
    isPaused: snapshot.isPaused,
    modeWire: snapshot.modeWire,
    accumulatedDurationSec: snapshot.accumulatedDurationSec,
    observedAtUtcMicros: observedAtUtc.microsecondsSinceEpoch,
    plannedDurationSec: snapshot.plannedDurationSec,
    linkLabel: snapshot.linkLabel,
  );

  final String sessionId;
  final bool isRunning;
  final bool isPaused;
  final String modeWire;
  final int accumulatedDurationSec;
  final int observedAtUtcMicros;
  final int? plannedDurationSec;
  final String? linkLabel;

  bool get isInterval => modeWire == 'interval';

  /// The cosmetic elapsed seconds to display at wall instant [nowUtc]
  /// (R-FOCUS-002). Never negative; a running session adds the time since the
  /// snapshot was observed, a paused session shows only the durable anchor.
  int displayedElapsedSec(DateTime nowUtc) {
    if (!isRunning) {
      return accumulatedDurationSec;
    }
    final int deltaSec =
        (nowUtc.microsecondsSinceEpoch - observedAtUtcMicros) ~/ 1000000;
    return accumulatedDurationSec + (deltaSec < 0 ? 0 : deltaSec);
  }
}

// ---------------------------------------------------------------------------
// Active session loader + intent controller.
// ---------------------------------------------------------------------------

const Failure _unavailableFailure = Failure(
  kind: FailureKind.unavailableCapability,
  code: 'focus.unavailable',
  safeMessageKey: 'error.capability',
  retryable: false,
);

/// Loads the single open focus session and orchestrates the start/pause/resume/
/// end intents over the durable command contract (R-FOCUS-001..003).
///
/// It holds no business rules: it maps a UI intent to a command, awaits the
/// committed result, and reloads the active-session read so the screen reflects
/// the new local canonical state (R-HOME-005). Reads run against the active
/// local generation, so the view is always available offline (R-GEN-001).
final class FocusController extends AsyncNotifier<FocusSessionView?> {
  @override
  Future<FocusSessionView?> build() async {
    final ProfileId? profile = ref.watch(focusProfileProvider);
    final FocusTodayContract? contract = ref.watch(focusContractProvider);
    if (profile == null || contract == null) {
      return null;
    }
    final FocusTodaySnapshot? snapshot = await contract.activeSession(profile);
    if (snapshot == null) {
      return null;
    }
    return FocusSessionView.fromSnapshot(
      snapshot,
      ref.read(focusClockProvider).utcNow(),
    );
  }

  void reload() => ref.invalidateSelf();

  ProfileId? get _profile => ref.read(focusProfileProvider);
  FocusCommandService? get _commands => ref.read(focusCommandServiceProvider);
  CommandId _id() => ref.read(focusCommandIdFactoryProvider)();

  /// Starts an open-ended count-up session in the default Life Area
  /// (R-FOCUS-001).
  Future<Result<CommittedCommandResult>> startCountUp() {
    final LifeAreaId? area = ref.read(focusDefaultAreaProvider);
    if (area == null) {
      return _fail();
    }
    return _start(StartFocusSessionInput.countUp(lifeAreaId: area.value));
  }

  /// Starts a timed interval session from a named [preset] (R-FOCUS-004).
  Future<Result<CommittedCommandResult>> startPreset(FocusPreset preset) {
    final LifeAreaId? area = ref.read(focusDefaultAreaProvider);
    if (area == null) {
      return _fail();
    }
    return _start(
      StartFocusSessionInput(lifeAreaId: area.value, preset: preset),
    );
  }

  Future<Result<CommittedCommandResult>> _start(
    StartFocusSessionInput input,
  ) async {
    final FocusCommandService? commands = _commands;
    final ProfileId? profile = _profile;
    if (commands == null || profile == null) {
      return _fail();
    }
    final Result<CommittedCommandResult> result = await commands.start(
      commandId: _id(),
      profileId: profile,
      input: input,
    );
    if (result is Success<CommittedCommandResult>) {
      reload();
    }
    return result;
  }

  /// Pauses the running session (R-FOCUS-003).
  Future<Result<CommittedCommandResult>> pause() => _transition(
    (FocusCommandService c, ProfileId p, String id) => c.pause(
      commandId: _id(),
      profileId: p,
      input: PauseFocusSessionInput(sessionId: id),
    ),
  );

  /// Resumes the paused session (R-FOCUS-003).
  Future<Result<CommittedCommandResult>> resume() => _transition(
    (FocusCommandService c, ProfileId p, String id) => c.resume(
      commandId: _id(),
      profileId: p,
      input: ResumeFocusSessionInput(sessionId: id),
    ),
  );

  /// Ends the open session (R-FOCUS-003).
  Future<Result<CommittedCommandResult>> end() => _transition(
    (FocusCommandService c, ProfileId p, String id) => c.end(
      commandId: _id(),
      profileId: p,
      input: EndFocusSessionInput(sessionId: id),
    ),
  );

  Future<Result<CommittedCommandResult>> _transition(
    Future<Result<CommittedCommandResult>> Function(
      FocusCommandService commands,
      ProfileId profile,
      String sessionId,
    )
    run,
  ) async {
    final FocusCommandService? commands = _commands;
    final ProfileId? profile = _profile;
    final String? sessionId = state.value?.sessionId;
    if (commands == null || profile == null || sessionId == null) {
      return _fail();
    }
    final Result<CommittedCommandResult> result = await run(
      commands,
      profile,
      sessionId,
    );
    if (result is Success<CommittedCommandResult>) {
      reload();
    }
    return result;
  }

  Future<Result<CommittedCommandResult>> _fail() async =>
      const Failed<CommittedCommandResult>(_unavailableFailure);
}

final AsyncNotifierProvider<FocusController, FocusSessionView?>
focusControllerProvider =
    AsyncNotifierProvider<FocusController, FocusSessionView?>(
      FocusController.new,
    );

/// A lightweight one-second ticker used ONLY to recompute the displayed elapsed
/// time from the durable accumulated seconds plus the running segment
/// (R-FOCUS-002). It is cosmetic: nothing here is persisted. Auto-disposes so
/// the periodic timer stops when the Focus screen is not mounted.
final focusTickerProvider = StreamProvider.autoDispose<int>((Ref ref) {
  return Stream<int>.periodic(const Duration(seconds: 1), (int tick) => tick);
});

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

final Random _random = Random();

CommandId _defaultCommandId() {
  final int micros = DateTime.now().toUtc().microsecondsSinceEpoch;
  final String salt = _random.nextInt(1 << 32).toRadixString(16);
  return CommandId('cmd-$micros-$salt');
}

final class _SystemUtcClock implements Clock {
  const _SystemUtcClock();

  @override
  DateTime utcNow() => DateTime.now().toUtc();

  @override
  String timezoneId() => 'UTC';
}
