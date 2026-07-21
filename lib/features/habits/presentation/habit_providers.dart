import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/habits/application/habit_command_service.dart';
import 'package:forge/features/habits/application/habit_commands.dart';
import 'package:forge/features/habits/application/habit_query_service.dart';

// ---------------------------------------------------------------------------
// Composition seams. Defaults keep the running app safe and honest before the
// encrypted runtime is wired; the composition root and tests override them. The
// habits feature owns its own seams so it never imports another feature's
// presentation or infrastructure (design.md §4).
// ---------------------------------------------------------------------------

/// The active local profile, or null when no generation is open yet.
final Provider<ProfileId?> habitsProfileProvider = Provider<ProfileId?>(
  (Ref ref) => null,
);

/// The habits feature's exported read contract. Null until wired.
final Provider<HabitQueryService?> habitsQueryServiceProvider =
    Provider<HabitQueryService?>((Ref ref) => null);

/// The durable habit command contract. Null until wired.
final Provider<HabitCommandService?> habitsCommandServiceProvider =
    Provider<HabitCommandService?>((Ref ref) => null);

/// Trusted clock used to resolve the current local date for the checklist.
final Provider<Clock> habitsClockProvider = Provider<Clock>(
  (Ref ref) => const _SystemUtcClock(),
);

/// Produces a fresh unique [CommandId] per durable command (R-GEN-005).
final Provider<CommandId Function()> habitsCommandIdFactoryProvider =
    Provider<CommandId Function()>((Ref ref) => _defaultCommandId);

/// Whether the habits read stack is wired at all (used for the
/// empty/unavailable distinction in the UI).
final Provider<bool> habitsConfiguredProvider = Provider<bool>((Ref ref) {
  return ref.watch(habitsProfileProvider) != null &&
      ref.watch(habitsQueryServiceProvider) != null;
});

/// The current local date derived from the trusted clock. The planning-day
/// boundary is user-configurable in a later wave (R-GEN-004); habits use the
/// UTC calendar day, which tests pin deterministically via a fake clock.
LocalDate _todayLocalDate(Ref ref) {
  final DateTime now = ref.watch(habitsClockProvider).utcNow();
  return LocalDate(now.year, now.month, now.day);
}

// ---------------------------------------------------------------------------
// Today habit checklist (R-HOME-001, R-HABIT-003).
// ---------------------------------------------------------------------------

/// Loads today's habit occurrences for the check-in surface. Reads run against
/// the active local generation, so the checklist is always available offline
/// (R-GEN-001).
final class HabitTodayController extends AsyncNotifier<List<HabitTodayEntry>> {
  @override
  Future<List<HabitTodayEntry>> build() async {
    final ProfileId? profile = ref.watch(habitsProfileProvider);
    final HabitQueryService? query = ref.watch(habitsQueryServiceProvider);
    if (profile == null || query == null) {
      return const <HabitTodayEntry>[];
    }
    return query.todayChecklist(
      profileId: profile,
      onDate: _todayLocalDate(ref),
    );
  }

  void reload() => ref.invalidateSelf();
}

final AsyncNotifierProvider<HabitTodayController, List<HabitTodayEntry>>
habitTodayProvider =
    AsyncNotifierProvider<HabitTodayController, List<HabitTodayEntry>>(
      HabitTodayController.new,
    );

// ---------------------------------------------------------------------------
// History, calendar, and statistics projections (R-HABIT-004, R-HABIT-007).
// ---------------------------------------------------------------------------

/// Default look-back window for the history and statistics surfaces.
const int _defaultWindowDays = 365;

/// The habit's occurrence history over the default window, newest first.
final habitHistoryProvider = FutureProvider.autoDispose
    .family<List<HabitOccurrenceView>, String>((Ref ref, String habitId) async {
      final ProfileId? profile = ref.watch(habitsProfileProvider);
      final HabitQueryService? query = ref.watch(habitsQueryServiceProvider);
      if (profile == null || query == null) {
        return const <HabitOccurrenceView>[];
      }
      final LocalDate today = _todayLocalDate(ref);
      return query.history(
        profileId: profile,
        habitId: HabitId(habitId),
        from: today.addDays(-_defaultWindowDays),
        to: today,
      );
    });

/// The habit's transparent streak + consistency statistics over the default
/// window under metric policy v1 (R-HABIT-004, R-HABIT-007).
final habitStatisticsProvider = FutureProvider.autoDispose
    .family<HabitStatistics?, String>((Ref ref, String habitId) async {
      final ProfileId? profile = ref.watch(habitsProfileProvider);
      final HabitQueryService? query = ref.watch(habitsQueryServiceProvider);
      if (profile == null || query == null) {
        return null;
      }
      final LocalDate today = _todayLocalDate(ref);
      return query.statistics(
        profileId: profile,
        habitId: HabitId(habitId),
        from: today.addDays(-_defaultWindowDays),
        to: today,
      );
    });

/// A descriptive summary for the detail header, or null when unavailable.
final habitSummaryProvider = FutureProvider.autoDispose
    .family<HabitSummary?, String>((Ref ref, String habitId) async {
      final ProfileId? profile = ref.watch(habitsProfileProvider);
      final HabitQueryService? query = ref.watch(habitsQueryServiceProvider);
      if (profile == null || query == null) {
        return null;
      }
      return query.summary(profileId: profile, habitId: HabitId(habitId));
    });

/// Parameters identifying a habit's calendar month.
typedef HabitCalendarKey = ({String habitId, int year, int month});

/// The habit's occurrences for a calendar month, keyed by anchor day.
final habitCalendarProvider = FutureProvider.autoDispose
    .family<HabitCalendarMonth?, HabitCalendarKey>((
      Ref ref,
      HabitCalendarKey key,
    ) async {
      final ProfileId? profile = ref.watch(habitsProfileProvider);
      final HabitQueryService? query = ref.watch(habitsQueryServiceProvider);
      if (profile == null || query == null) {
        return null;
      }
      return query.calendarMonth(
        profileId: profile,
        habitId: HabitId(key.habitId),
        year: key.year,
        month: key.month,
      );
    });

// ---------------------------------------------------------------------------
// Mutating actions + neutral feedback (R-HABIT-005, R-HABIT-006).
// ---------------------------------------------------------------------------

/// Transient feedback from the most recent habit action. Success carries no
/// judgemental language; a miss is never announced as a failure of the user
/// (R-HABIT-006).
sealed class HabitFeedback {
  const HabitFeedback();
}

final class HabitFeedbackNone extends HabitFeedback {
  const HabitFeedbackNone();
}

/// A neutral confirmation keyed by a stable message code the view localizes.
final class HabitFeedbackMessage extends HabitFeedback {
  const HabitFeedbackMessage(this.messageCode);
  final String messageCode;
}

final class HabitFeedbackError extends HabitFeedback {
  const HabitFeedbackError(this.failure);
  final Failure failure;
}

const Failure _unavailableFailure = Failure(
  kind: FailureKind.unavailableCapability,
  code: 'habits.unavailable',
  safeMessageKey: 'error.capability',
  retryable: false,
);

/// Orchestrates habit check-in, skip, and correction over the durable command
/// contract, then refreshes affected read providers. It holds no business
/// rules; occurrence and metric semantics live entirely in the domain policies
/// and the command service.
final class HabitActionsController extends Notifier<HabitFeedback> {
  @override
  HabitFeedback build() => const HabitFeedbackNone();

  void dismiss() => state = const HabitFeedbackNone();

  CommandId _id() => ref.read(habitsCommandIdFactoryProvider)();
  ProfileId? get _profile => ref.read(habitsProfileProvider);
  HabitCommandService? get _commands => ref.read(habitsCommandServiceProvider);

  bool get _wired => _commands != null && _profile != null;

  void _refresh(String habitId) {
    ref.invalidate(habitTodayProvider);
    ref.invalidate(habitHistoryProvider(habitId));
    ref.invalidate(habitStatisticsProvider(habitId));
  }

  /// Records an append-only check-in against the occurrence on [onDate]
  /// (R-HABIT-003, R-HABIT-005). [rawValue]/[rawUnit] apply to numeric targets;
  /// a boolean uses [ObservationInputKind.booleanTrue] and an abstinence slip
  /// uses [ObservationInputKind.violation].
  Future<bool> checkIn({
    required String habitId,
    required LocalDate onDate,
    required ObservationInputKind kind,
    num? rawValue,
    String? rawUnit,
    String? note,
    String messageCode = 'checkedIn',
  }) {
    return _run(
      habitId,
      messageCode,
      () => _commands!.checkIn(
        commandId: _id(),
        profileId: _profile!,
        habitId: HabitId(habitId),
        input: CheckInInput(
          onDate: onDate,
          kind: kind,
          rawValue: rawValue,
          rawUnit: rawUnit,
          note: note,
        ),
      ),
    );
  }

  /// Skips the occurrence on [onDate] with an optional [reason] (R-HABIT-005).
  /// A skip is neutral: it never breaks streak continuity and stays in the
  /// consistency denominator (R-HABIT-004, R-HABIT-007).
  Future<bool> skip({
    required String habitId,
    required LocalDate onDate,
    String? reason,
  }) {
    return _run(
      habitId,
      'skipped',
      () => _commands!.skipOccurrence(
        commandId: _id(),
        profileId: _profile!,
        habitId: HabitId(habitId),
        input: SkipOccurrenceInput(onDate: onDate, reason: reason),
      ),
    );
  }

  /// Appends a superseding correction of a prior observation (R-HABIT-005). The
  /// superseded record stays in the audit log.
  Future<bool> correct({
    required String habitId,
    required String logicalId,
    required ObservationInputKind kind,
    num? rawValue,
    String? rawUnit,
    String? note,
  }) {
    return _run(
      habitId,
      'corrected',
      () => _commands!.correctObservation(
        commandId: _id(),
        profileId: _profile!,
        habitId: HabitId(habitId),
        input: CorrectObservationInput(
          logicalId: logicalId,
          kind: kind,
          rawValue: rawValue,
          rawUnit: rawUnit,
          note: note,
        ),
      ),
    );
  }

  Future<bool> _run(
    String habitId,
    String messageCode,
    Future<Result<CommittedCommandResult>> Function() run,
  ) async {
    if (!_wired) {
      state = const HabitFeedbackError(_unavailableFailure);
      return false;
    }
    final Result<CommittedCommandResult> result = await run();
    switch (result) {
      case Success<CommittedCommandResult>():
        _refresh(habitId);
        state = HabitFeedbackMessage(messageCode);
        return true;
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        state = HabitFeedbackError(failure);
        return false;
    }
  }
}

final NotifierProvider<HabitActionsController, HabitFeedback>
habitActionsProvider = NotifierProvider<HabitActionsController, HabitFeedback>(
  HabitActionsController.new,
);

// ---------------------------------------------------------------------------
// Backfill / correction impact preview (R-HABIT-005).
// ---------------------------------------------------------------------------

/// Parameters for a metric-impact preview of a backfilled/corrected occurrence.
typedef HabitImpactKey = ({
  String habitId,
  String onDateIso,
  HabitPreviewOutcome outcome,
});

/// The projected metric impact of the requested backfill/correction, computed
/// without committing anything (R-HABIT-005). Null until the read stack is
/// wired.
final habitImpactPreviewProvider = FutureProvider.autoDispose
    .family<HabitImpactPreview?, HabitImpactKey>((
      Ref ref,
      HabitImpactKey key,
    ) async {
      final ProfileId? profile = ref.watch(habitsProfileProvider);
      final HabitQueryService? query = ref.watch(habitsQueryServiceProvider);
      if (profile == null || query == null) {
        return null;
      }
      final LocalDate onDate = LocalDate.parse(key.onDateIso);
      final LocalDate today = _todayLocalDate(ref);
      final LocalDate to = today >= onDate ? today : onDate;
      return query.impactPreview(
        profileId: profile,
        habitId: HabitId(key.habitId),
        from: onDate.addDays(-_defaultWindowDays),
        to: to,
        onDate: onDate,
        outcome: key.outcome,
      );
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
