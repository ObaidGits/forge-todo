import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/focus/application/focus_command_service.dart';
import 'package:forge/features/focus/application/focus_commands.dart';
import 'package:forge/features/focus/application/focus_today_contract.dart';
import 'package:forge/features/habits/application/habit_command_service.dart';
import 'package:forge/features/habits/application/habit_commands.dart';
import 'package:forge/features/habits/application/habit_query_service.dart';
import 'package:forge/features/home/application/home_content.dart';
import 'package:forge/features/home/application/home_layout_store.dart';
import 'package:forge/features/home/application/home_query_service.dart';
import 'package:forge/features/home/domain/home_layout.dart';
import 'package:forge/features/home/domain/home_section.dart';
import 'package:forge/features/learning/application/learning_resume_contract.dart';
import 'package:forge/features/tasks/application/task_command_service.dart';
import 'package:forge/features/tasks/application/task_commands.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';

// ---------------------------------------------------------------------------
// Composition seams. Defaults keep the running app safe and honest before the
// encrypted runtime is wired; the composition root and tests override them.
// ---------------------------------------------------------------------------

/// The active local profile, or null when no generation is open yet.
final Provider<ProfileId?> activeProfileProvider = Provider<ProfileId?>(
  (Ref ref) => null,
);

/// The Life Area a title-only quick capture inherits (R-TASK-001). Null when no
/// profile/area is available, in which case capture is unavailable.
final Provider<LifeAreaId?> quickCaptureAreaProvider = Provider<LifeAreaId?>(
  (Ref ref) => null,
);

/// Optional Life Area filter applied to the Today agenda.
final Provider<LifeAreaId?> homeLifeAreaFilterProvider = Provider<LifeAreaId?>(
  (Ref ref) => null,
);

/// The tasks feature's exported read contract. Null until wired.
final Provider<TaskQueryService?> taskQueryServiceProvider =
    Provider<TaskQueryService?>((Ref ref) => null);

/// The tasks feature's durable command contract used by quick capture and
/// inline completion. Null until wired.
final Provider<TaskCommandService?> taskCommandServiceProvider =
    Provider<TaskCommandService?>((Ref ref) => null);

/// The learning feature's exported resume contract used to surface the Today
/// active-study recommendation (R-HOME-001, R-LEARN-003). Null until the
/// learning stack is wired at the composition root.
final Provider<LearningResumeContract?> learningResumeContractProvider =
    Provider<LearningResumeContract?>((Ref ref) => null);

/// The habits feature's exported read contract used to surface today's habit
/// checklist and the habit consistency ring (R-HOME-001, R-HABIT-003). Null
/// until the habits stack is wired at the composition root.
final Provider<HabitQueryService?> homeHabitQueryServiceProvider =
    Provider<HabitQueryService?>((Ref ref) => null);

/// The habits feature's durable command contract used by inline check-in on
/// Today (R-HOME-003). Null until wired.
final Provider<HabitCommandService?> homeHabitCommandServiceProvider =
    Provider<HabitCommandService?>((Ref ref) => null);

/// The focus feature's exported Today contract used to surface the active focus
/// session (R-HOME-001, R-FOCUS-001..003). Null until wired.
final Provider<FocusTodayContract?> homeFocusContractProvider =
    Provider<FocusTodayContract?>((Ref ref) => null);

/// The focus feature's durable command contract used to start a focus session
/// without leaving Today (R-HOME-003). Null until wired.
final Provider<FocusCommandService?> homeFocusCommandServiceProvider =
    Provider<FocusCommandService?>((Ref ref) => null);

/// Durable Today-layout preference store (R-HOME-002). Defaults to a volatile
/// in-memory store so the app is usable before persistence is wired.
final Provider<HomeLayoutStore> homeLayoutStoreProvider =
    Provider<HomeLayoutStore>((Ref ref) => InMemoryHomeLayoutStore());

/// Trusted clock for planning-day computation.
final Provider<Clock> homeClockProvider = Provider<Clock>(
  (Ref ref) => const _SystemUtcClock(),
);

/// Produces a fresh unique [CommandId] per durable command (R-GEN-005).
final Provider<CommandId Function()> commandIdFactoryProvider =
    Provider<CommandId Function()>((Ref ref) => _defaultCommandId);

/// Composes the Home query facade from the tasks contract (design.md §4).
final Provider<HomeQueryService?> homeQueryServiceProvider =
    Provider<HomeQueryService?>((Ref ref) {
      final TaskQueryService? tasks = ref.watch(taskQueryServiceProvider);
      if (tasks == null) {
        return null;
      }
      return HomeQueryService(
        tasks,
        learning: ref.watch(learningResumeContractProvider),
        habits: ref.watch(homeHabitQueryServiceProvider),
        focus: ref.watch(homeFocusContractProvider),
      );
    });

// ---------------------------------------------------------------------------
// Today content + layout controller.
// ---------------------------------------------------------------------------

/// Immutable Today view state: the user's section layout plus reconstructed
/// content. [configured] is false when no profile/query service is wired, so
/// the view shows a calm empty state rather than an error.
final class HomeState {
  const HomeState({
    required this.layout,
    required this.content,
    required this.configured,
  });

  final HomeLayout layout;
  final HomeTodayContent content;
  final bool configured;
}

/// Loads and mutates the Today screen model (design.md §6). Business rules live
/// in application services; this controller only orchestrates and holds
/// transient state.
final class HomeController extends AsyncNotifier<HomeState> {
  @override
  Future<HomeState> build() async {
    final ProfileId? profile = ref.watch(activeProfileProvider);
    final HomeQueryService? query = ref.watch(homeQueryServiceProvider);
    final HomeLayoutStore store = ref.watch(homeLayoutStoreProvider);

    if (profile == null || query == null) {
      return HomeState(
        layout: HomeLayout.defaultLayout,
        content: const HomeTodayContent.empty(),
        configured: false,
      );
    }

    final Clock clock = ref.watch(homeClockProvider);
    final _PlanningDay day = _PlanningDay.from(clock.utcNow());
    final HomeLayout layout = await store.load(profile);
    final HomeTodayContent content = await query.today(
      profileId: profile,
      currentPlanningDate: day.isoDate,
      dayStartUtcMicros: day.startUtcMicros,
      nowUtcMicros: day.nowUtcMicros,
      lifeAreaId: ref.watch(homeLifeAreaFilterProvider),
    );
    return HomeState(layout: layout, content: content, configured: true);
  }

  /// Re-reads content from Drift (R-HOME-005): used after a committed capture or
  /// inline completion so the calm view reflects the new local canonical state.
  void reload() => ref.invalidateSelf();

  Future<void> moveSectionUp(HomeSectionKind kind) =>
      _updateLayout((HomeLayout l) => l.moveUp(kind));

  Future<void> moveSectionDown(HomeSectionKind kind) =>
      _updateLayout((HomeLayout l) => l.moveDown(kind));

  Future<void> hideSection(HomeSectionKind kind) =>
      _updateLayout((HomeLayout l) => l.hide(kind));

  Future<void> showSection(HomeSectionKind kind) =>
      _updateLayout((HomeLayout l) => l.show(kind));

  Future<void> resetLayout() => _updateLayout((HomeLayout l) => l.reset());

  /// Toggles inline task completion without leaving the screen (R-HOME-003).
  Future<Result<CommittedCommandResult>> setTaskComplete({
    required String taskId,
    required bool complete,
  }) async {
    final TaskCommandService? commands = ref.read(taskCommandServiceProvider);
    final ProfileId? profile = ref.read(activeProfileProvider);
    if (commands == null || profile == null) {
      return const Failed<CommittedCommandResult>(_unavailableFailure);
    }
    final CommandId commandId = ref.read(commandIdFactoryProvider)();
    final TaskId id = TaskId(taskId);
    final Result<CommittedCommandResult> result = complete
        ? await commands.complete(
            commandId: commandId,
            profileId: profile,
            taskId: id,
          )
        : await commands.reopen(
            commandId: commandId,
            profileId: profile,
            taskId: id,
          );
    if (result is Success<CommittedCommandResult>) {
      reload();
    }
    return result;
  }

  /// Records an append-only habit check-in from Today without leaving the
  /// screen (R-HOME-003, R-HABIT-003). [kind] selects the observation: a
  /// boolean done, a numeric value (with [rawValue]/[rawUnit]), or an
  /// abstinence slip. Reloads Today on commit so the checklist reflects the new
  /// local canonical state (R-HOME-005).
  Future<Result<CommittedCommandResult>> checkInHabit({
    required String habitId,
    required String onDateIso,
    required ObservationInputKind kind,
    num? rawValue,
    String? rawUnit,
  }) async {
    final HabitCommandService? commands = ref.read(
      homeHabitCommandServiceProvider,
    );
    final ProfileId? profile = ref.read(activeProfileProvider);
    if (commands == null || profile == null) {
      return const Failed<CommittedCommandResult>(_unavailableFailure);
    }
    final Result<CommittedCommandResult> result = await commands.checkIn(
      commandId: ref.read(commandIdFactoryProvider)(),
      profileId: profile,
      habitId: HabitId(habitId),
      input: CheckInInput(
        onDate: LocalDate.parse(onDateIso),
        kind: kind,
        rawValue: rawValue,
        rawUnit: rawUnit,
      ),
    );
    if (result is Success<CommittedCommandResult>) {
      reload();
    }
    return result;
  }

  /// Starts a count-up focus session in [lifeAreaId] without leaving Today
  /// (R-HOME-003, R-FOCUS-001). Reloads Today on commit so the focus slot shows
  /// the new active session (R-HOME-005).
  Future<Result<CommittedCommandResult>> startFocus({
    required LifeAreaId lifeAreaId,
  }) async {
    final FocusCommandService? commands = ref.read(
      homeFocusCommandServiceProvider,
    );
    final ProfileId? profile = ref.read(activeProfileProvider);
    if (commands == null || profile == null) {
      return const Failed<CommittedCommandResult>(_unavailableFailure);
    }
    final Result<CommittedCommandResult> result = await commands.start(
      commandId: ref.read(commandIdFactoryProvider)(),
      profileId: profile,
      input: StartFocusSessionInput.countUp(lifeAreaId: lifeAreaId.value),
    );
    if (result is Success<CommittedCommandResult>) {
      reload();
    }
    return result;
  }

  Future<void> _updateLayout(HomeLayout Function(HomeLayout) transform) async {
    final HomeState? current = state.value;
    if (current == null) {
      return;
    }
    final HomeLayout next = transform(current.layout);
    final ProfileId? profile = ref.read(activeProfileProvider);
    if (profile != null) {
      await ref.read(homeLayoutStoreProvider).save(profile, next);
    }
    state = AsyncData<HomeState>(
      HomeState(
        layout: next,
        content: current.content,
        configured: current.configured,
      ),
    );
  }
}

final AsyncNotifierProvider<HomeController, HomeState> homeControllerProvider =
    AsyncNotifierProvider<HomeController, HomeState>(HomeController.new);

// ---------------------------------------------------------------------------
// Quick capture controller (R-HOME-003, R-GEN-001, NFR-USAB-001).
// ---------------------------------------------------------------------------

/// Transient quick-capture state. Committed feedback carries the stable
/// committed result (never a dispatch acknowledgement) so the UI can confirm
/// the task is durably stored (R-GEN-005).
sealed class QuickCaptureState {
  const QuickCaptureState();
}

final class QuickCaptureIdle extends QuickCaptureState {
  const QuickCaptureIdle();
}

final class QuickCaptureSaving extends QuickCaptureState {
  const QuickCaptureSaving(this.title);
  final String title;
}

final class QuickCaptureCommitted extends QuickCaptureState {
  const QuickCaptureCommitted({
    required this.taskId,
    required this.title,
    required this.committedAtUtcMicros,
  });
  final String taskId;
  final String title;
  final int committedAtUtcMicros;
}

final class QuickCaptureFailed extends QuickCaptureState {
  const QuickCaptureFailed({
    required this.failure,
    required this.retainedInput,
  });
  final Failure failure;

  /// The text the user typed; retained so a failure never loses input
  /// (ux-design Error Handling).
  final String retainedInput;
}

/// Orchestrates title-only quick capture (R-TASK-001). It commits explicit
/// local state through the command bus and returns the committed result, then
/// asks Home to reload so the new row appears within the feedback threshold
/// (NFR-USAB-001, NFR-PERF-006).
final class QuickCaptureController extends Notifier<QuickCaptureState> {
  @override
  QuickCaptureState build() => const QuickCaptureIdle();

  Future<bool> submit(String rawTitle) async {
    final String title = rawTitle.trim();
    if (title.isEmpty) {
      state = const QuickCaptureFailed(
        failure: _emptyTitleFailure,
        retainedInput: '',
      );
      return false;
    }

    final TaskCommandService? commands = ref.read(taskCommandServiceProvider);
    final ProfileId? profile = ref.read(activeProfileProvider);
    final LifeAreaId? area = ref.read(quickCaptureAreaProvider);
    if (commands == null || profile == null || area == null) {
      state = QuickCaptureFailed(
        failure: _unavailableFailure,
        retainedInput: title,
      );
      return false;
    }

    state = QuickCaptureSaving(title);
    final CommandId commandId = ref.read(commandIdFactoryProvider)();
    final Result<CommittedCommandResult> result = await commands.create(
      commandId: commandId,
      profileId: profile,
      input: CreateTaskInput(lifeAreaId: area, title: title),
    );

    return result.fold(
      success: (CommittedCommandResult committed) {
        state = QuickCaptureCommitted(
          taskId: _taskIdFromPayload(committed.resultPayload),
          title: title,
          committedAtUtcMicros: ref
              .read(homeClockProvider)
              .utcNow()
              .microsecondsSinceEpoch,
        );
        ref.read(homeControllerProvider.notifier).reload();
        return true;
      },
      failure: (Failure failure) {
        state = QuickCaptureFailed(failure: failure, retainedInput: title);
        return false;
      },
    );
  }

  /// Clears transient feedback once acknowledged by the UI.
  void reset() => state = const QuickCaptureIdle();
}

final NotifierProvider<QuickCaptureController, QuickCaptureState>
quickCaptureControllerProvider =
    NotifierProvider<QuickCaptureController, QuickCaptureState>(
      QuickCaptureController.new,
    );

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

const Failure _unavailableFailure = Failure(
  kind: FailureKind.unavailableCapability,
  code: 'home.capture_unavailable',
  safeMessageKey: 'error.capability',
  retryable: false,
);

const Failure _emptyTitleFailure = Failure(
  kind: FailureKind.validation,
  code: 'home.capture_empty_title',
  safeMessageKey: 'error.validation',
  retryable: false,
);

String _taskIdFromPayload(String? payload) {
  if (payload == null || payload.isEmpty) {
    return '';
  }
  final Object? decoded = jsonDecode(payload);
  if (decoded is Map<String, Object?> && decoded['id'] is String) {
    return decoded['id'] as String;
  }
  return '';
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

/// The planning day derived from trusted now. The planning-day boundary is
/// user-configurable in a later wave (R-GEN-004); tasks-era Home uses the UTC
/// calendar day, which the tests pin deterministically via a fake clock.
final class _PlanningDay {
  const _PlanningDay({
    required this.isoDate,
    required this.startUtcMicros,
    required this.nowUtcMicros,
  });

  factory _PlanningDay.from(DateTime nowUtc) {
    final DateTime start = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day);
    final String iso =
        '${start.year.toString().padLeft(4, '0')}-'
        '${start.month.toString().padLeft(2, '0')}-'
        '${start.day.toString().padLeft(2, '0')}';
    return _PlanningDay(
      isoDate: iso,
      startUtcMicros: start.microsecondsSinceEpoch,
      nowUtcMicros: nowUtc.microsecondsSinceEpoch,
    );
  }

  final String isoDate;
  final int startUtcMicros;
  final int nowUtcMicros;
}
