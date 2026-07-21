import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/fitness/application/fitness_command_service.dart';
import 'package:forge/features/fitness/application/fitness_commands.dart';
import 'package:forge/features/fitness/application/fitness_query_service.dart';
import 'package:forge/features/fitness/domain/body_measurement.dart';
import 'package:forge/features/fitness/domain/workout_session.dart';
import 'package:forge/features/fitness/domain/workout_template.dart';

// ---------------------------------------------------------------------------
// Composition seams. Defaults keep the running app honest before the encrypted
// runtime is wired; the composition root and tests override them. The fitness
// feature owns its own seams so its presentation never imports another
// feature's presentation or infrastructure, and never touches fitness
// infrastructure directly (design.md §4). Water tracking is intentionally not
// surfaced here: it is optional and disabled by default (R-FIT-003), so V1 of
// this screen omits it entirely rather than wiring a half-enabled toggle.
// ---------------------------------------------------------------------------

/// The active local profile, or null when no generation is open yet.
final Provider<ProfileId?> fitnessProfileProvider = Provider<ProfileId?>(
  (Ref ref) => null,
);

/// The fitness read/query surface. Null until wired.
final Provider<FitnessQueryService?> fitnessQueryServiceProvider =
    Provider<FitnessQueryService?>((Ref ref) => null);

/// The durable fitness command surface. Null until wired.
final Provider<FitnessCommandService?> fitnessCommandServiceProvider =
    Provider<FitnessCommandService?>((Ref ref) => null);

/// A trusted UTC clock used to stamp new sessions and measurements.
final Provider<Clock> fitnessClockProvider = Provider<Clock>(
  (Ref ref) => const _SystemUtcClock(),
);

/// The default Life Area a newly created fitness record inherits (R-GEN-002).
/// Null when unavailable, in which case create affordances are unavailable.
final Provider<LifeAreaId?> fitnessDefaultAreaProvider = Provider<LifeAreaId?>(
  (Ref ref) => null,
);

/// Produces a fresh unique [CommandId] per durable command (R-GEN-005).
final Provider<CommandId Function()> fitnessCommandIdFactoryProvider =
    Provider<CommandId Function()>((Ref ref) => _defaultCommandId);

/// Whether the fitness read + command stack is wired at all (used for the
/// empty/not-configured distinction in the UI).
final Provider<bool> fitnessConfiguredProvider = Provider<bool>((Ref ref) {
  return ref.watch(fitnessProfileProvider) != null &&
      ref.watch(fitnessQueryServiceProvider) != null;
});

// ---------------------------------------------------------------------------
// Overview projection (R-FIT-001, R-FIT-002, R-FIT-004).
// ---------------------------------------------------------------------------

/// The composed fitness overview: rank-ordered active workout templates, recent
/// logged sessions (newest first), and body-weight measurements preserving the
/// exact entered value/unit. These are the underlying records themselves, so no
/// medical interpretation is layered on top (R-FIT-004, R-FIT-005).
final class FitnessOverview {
  const FitnessOverview({
    required this.templates,
    required this.sessions,
    required this.measurements,
  });

  final List<WorkoutTemplate> templates;
  final List<WorkoutSession> sessions;
  final List<BodyMeasurement> measurements;

  bool get isEmpty =>
      templates.isEmpty && sessions.isEmpty && measurements.isEmpty;
}

/// The full inclusive UTC-micros window used to read all history. Reads run
/// against the active local generation, so the overview is available offline
/// (R-GEN-001).
const int _windowFromUtc = 0;
const int _windowToUtc = 9223372036854775807;

/// Loads the fitness overview for the active profile.
final class FitnessOverviewController extends AsyncNotifier<FitnessOverview> {
  @override
  Future<FitnessOverview> build() async {
    final ProfileId? profile = ref.watch(fitnessProfileProvider);
    final FitnessQueryService? query = ref.watch(fitnessQueryServiceProvider);
    if (profile == null || query == null) {
      return const FitnessOverview(
        templates: <WorkoutTemplate>[],
        sessions: <WorkoutSession>[],
        measurements: <BodyMeasurement>[],
      );
    }
    final String id = profile.value;
    final List<WorkoutTemplate> templates = await query.workoutTemplates(id);
    final List<WorkoutSession> sessions = await query.sessionHistory(
      id,
      fromUtc: _windowFromUtc,
      toUtc: _windowToUtc,
    );
    final List<BodyMeasurement> measurements = await query
        .bodyMeasurementHistory(
          id,
          fromUtc: _windowFromUtc,
          toUtc: _windowToUtc,
        );
    return FitnessOverview(
      templates: templates,
      sessions: sessions,
      measurements: measurements,
    );
  }

  void reload() => ref.invalidateSelf();
}

final AsyncNotifierProvider<FitnessOverviewController, FitnessOverview>
fitnessOverviewProvider =
    AsyncNotifierProvider<FitnessOverviewController, FitnessOverview>(
      FitnessOverviewController.new,
    );

// ---------------------------------------------------------------------------
// Single workout detail projection (R-FIT-001, R-FIT-004).
// ---------------------------------------------------------------------------

/// One performed exercise plus its rank-ordered sets (the underlying records).
final class ExerciseWithSets {
  const ExerciseWithSets({required this.exercise, required this.sets});

  final ExerciseLog exercise;
  final List<SetLog> sets;
}

/// The composed detail of one logged workout session: the session record itself
/// plus its exercises and their sets, exactly as recorded (R-FIT-004, R-FIT-005).
final class FitnessWorkoutDetail {
  const FitnessWorkoutDetail({required this.session, required this.exercises});

  final WorkoutSession session;
  final List<ExerciseWithSets> exercises;
}

/// Loads the detail for a single workout session id. Auto-disposes when the
/// detail route is popped. Returns null when the stack is not wired or the
/// session does not exist.
final fitnessWorkoutDetailProvider = FutureProvider.autoDispose
    .family<FitnessWorkoutDetail?, String>((Ref ref, String sessionId) async {
      final ProfileId? profile = ref.watch(fitnessProfileProvider);
      final FitnessQueryService? query = ref.watch(fitnessQueryServiceProvider);
      if (profile == null || query == null) {
        return null;
      }
      final String id = profile.value;
      final WorkoutSession? session = await query.findWorkoutSession(
        id,
        sessionId,
      );
      if (session == null) {
        return null;
      }
      final List<ExerciseLog> exercises = await query.sessionExercises(
        id,
        sessionId,
      );
      final List<ExerciseWithSets> composed = <ExerciseWithSets>[];
      for (final ExerciseLog exercise in exercises) {
        final List<SetLog> sets = await query.exerciseSets(
          id,
          exercise.id.value,
        );
        composed.add(ExerciseWithSets(exercise: exercise, sets: sets));
      }
      return FitnessWorkoutDetail(session: session, exercises: composed);
    });

// ---------------------------------------------------------------------------
// Transient feedback.
// ---------------------------------------------------------------------------

/// Transient feedback from the most recent fitness action.
sealed class FitnessFeedback {
  const FitnessFeedback();
}

final class FitnessFeedbackNone extends FitnessFeedback {
  const FitnessFeedbackNone();
}

final class FitnessFeedbackError extends FitnessFeedback {
  const FitnessFeedbackError(this.failure);
  final Failure failure;
}

const Failure _unavailableFailure = Failure(
  kind: FailureKind.unavailableCapability,
  code: 'fitness.unavailable',
  safeMessageKey: 'error.capability',
  retryable: false,
);

// ---------------------------------------------------------------------------
// Actions controller (R-FIT-001, R-FIT-002).
// ---------------------------------------------------------------------------

/// Orchestrates fitness mutations over the durable command contract. It holds
/// no business rules; it maps a UI intent to a command, awaits the committed
/// result, refreshes the overview, and exposes transient error feedback. Unit
/// preservation is delegated entirely to the command service and domain, so an
/// entered value/unit is stored verbatim (R-FIT-002).
final class FitnessActionsController extends Notifier<FitnessFeedback> {
  @override
  FitnessFeedback build() => const FitnessFeedbackNone();

  void dismiss() => state = const FitnessFeedbackNone();

  CommandId _id() => ref.read(fitnessCommandIdFactoryProvider)();
  ProfileId? get _profile => ref.read(fitnessProfileProvider);
  FitnessCommandService? get _commands =>
      ref.read(fitnessCommandServiceProvider);
  Clock get _clock => ref.read(fitnessClockProvider);

  bool get _wired => _commands != null && _profile != null;

  int get _nowUtc => _clock.utcNow().microsecondsSinceEpoch;

  /// Creates a workout template with no planned exercises yet (R-FIT-001).
  /// Exercises can be added later; the empty template is a valid starting
  /// point. Returns true on success.
  Future<bool> createTemplate({
    required String title,
    required LifeAreaId lifeAreaId,
  }) async {
    if (!_wired) {
      state = const FitnessFeedbackError(_unavailableFailure);
      return false;
    }
    final List<WorkoutTemplate> existing =
        ref.read(fitnessOverviewProvider).value?.templates ??
        const <WorkoutTemplate>[];
    final String rank = _appendRank(
      existing.isEmpty ? null : existing.last.rank,
    );
    return _run(
      () => _commands!.createWorkoutTemplate(
        commandId: _id(),
        profileId: _profile!,
        templateId: WorkoutTemplateId(_uuid()),
        input: CreateWorkoutTemplateInput(
          lifeAreaId: lifeAreaId.value,
          title: title,
          rank: rank,
        ),
      ),
    );
  }

  /// Logs a workout session started now, with no exercises yet (R-FIT-001).
  /// The session is the durable record of a workout having happened; its
  /// exercises/sets can be added later. Returns true on success.
  Future<bool> logSession({
    required String title,
    required LifeAreaId lifeAreaId,
  }) async {
    if (!_wired) {
      state = const FitnessFeedbackError(_unavailableFailure);
      return false;
    }
    return _run(
      () => _commands!.logWorkoutSession(
        commandId: _id(),
        profileId: _profile!,
        sessionId: WorkoutSessionId(_uuid()),
        input: LogWorkoutSessionInput(
          lifeAreaId: lifeAreaId.value,
          title: title,
          startedAtUtc: _nowUtc,
        ),
      ),
    );
  }

  /// Records a body-weight measurement, preserving the entered value/unit
  /// verbatim (R-FIT-002). Returns true on success.
  Future<bool> recordBodyWeight({
    required num value,
    required String unit,
    required LifeAreaId lifeAreaId,
  }) async {
    if (!_wired) {
      state = const FitnessFeedbackError(_unavailableFailure);
      return false;
    }
    return _run(
      () => _commands!.recordBodyMeasurement(
        commandId: _id(),
        profileId: _profile!,
        measurementId: BodyMeasurementId(_uuid()),
        input: RecordBodyMeasurementInput(
          lifeAreaId: lifeAreaId.value,
          value: value,
          unit: unit,
          measuredAtUtc: _nowUtc,
        ),
      ),
    );
  }

  Future<bool> _run(
    Future<Result<CommittedCommandResult>> Function() run,
  ) async {
    final Result<CommittedCommandResult> result = await run();
    switch (result) {
      case Success<CommittedCommandResult>():
        ref.invalidate(fitnessOverviewProvider);
        state = const FitnessFeedbackNone();
        return true;
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        state = FitnessFeedbackError(failure);
        return false;
    }
  }

  String _uuid() {
    // A presentation-owned unique id for a new record. The value is only an
    // opaque identifier; the durable id validation lives in the domain.
    final int micros = DateTime.now().toUtc().microsecondsSinceEpoch;
    final String salt = _random.nextInt(1 << 32).toRadixString(16);
    return 'fit-$micros-$salt';
  }
}

final NotifierProvider<FitnessActionsController, FitnessFeedback>
fitnessActionsProvider =
    NotifierProvider<FitnessActionsController, FitnessFeedback>(
      FitnessActionsController.new,
    );

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

/// A stable lowercase `a`-`z` ordering rank appended after [last] (mirrors the
/// learning/planner rank helpers). Keeping the tiny helper local avoids a
/// cross-feature import while producing ranks SQLite sorts without a custom
/// collation.
String _appendRank(String? last) {
  if (last == null || last.isEmpty) {
    return 'n';
  }
  final List<int> out = <int>[];
  int i = 0;
  while (true) {
    final int lo = i < last.length ? last.codeUnitAt(i) : 96; // one below 'a'
    const int hi = 123; // one above 'z'
    final int mid = (lo + hi) ~/ 2;
    if (mid != lo) {
      out.add(mid);
      return String.fromCharCodes(out);
    }
    out.add(lo);
    i += 1;
  }
}

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
