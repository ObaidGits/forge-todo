import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/planner/application/planner_command_service.dart';
import 'package:forge/features/planner/application/planner_commands.dart';
import 'package:forge/features/planner/domain/planner_repository.dart';
import 'package:forge/features/planner/domain/planning_period.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';

// ---------------------------------------------------------------------------
// Composition seams. Defaults keep the running app honest before the encrypted
// runtime is wired; the composition root and tests override them. The planner
// feature owns its own seams so its presentation never imports another
// feature's presentation nor its own infrastructure (design.md §4/§16). It
// depends only on the domain [PlannerRepository] read contract and the
// [PlannerCommandService] write contract, never a concrete repository.
// ---------------------------------------------------------------------------

/// The active local profile, or null when no generation is open yet.
final Provider<ProfileId?> plannerProfileProvider = Provider<ProfileId?>(
  (Ref ref) => null,
);

/// The planner read contract (domain repository). Null until wired.
final Provider<PlannerRepository?> plannerRepositoryProvider =
    Provider<PlannerRepository?>((Ref ref) => null);

/// The durable planner command contract. Null until wired.
final Provider<PlannerCommandService?> plannerCommandServiceProvider =
    Provider<PlannerCommandService?>((Ref ref) => null);

/// Trusted UTC clock used to compute the current planning day (R-GEN-004).
final Provider<Clock> plannerClockProvider = Provider<Clock>(
  (Ref ref) => const _SystemUtcClock(),
);

/// The default (quick-capture) Life Area whose daily planning record the tab
/// edits (R-GEN-002, R-PLAN-001). Null when unavailable, in which case the
/// planner surface is unavailable.
final Provider<LifeAreaId?> plannerDefaultAreaProvider = Provider<LifeAreaId?>(
  (Ref ref) => null,
);

/// Produces a fresh unique [CommandId] per durable command (R-GEN-005).
final Provider<CommandId Function()> plannerCommandIdFactoryProvider =
    Provider<CommandId Function()>((Ref ref) => _defaultCommandId);

/// The ISO `YYYY-MM-DD` key of the current planning day, derived from the
/// trusted clock's calendar day (R-PLAN-001, R-GEN-004). The tasks-era planner
/// uses the UTC calendar day; a user-configurable day boundary lands later.
final Provider<String> plannerCurrentDayProvider = Provider<String>((Ref ref) {
  final DateTime now = ref.watch(plannerClockProvider).utcNow();
  return LocalDate(now.year, now.month, now.day).iso;
});

/// Whether the planner read + write stack is wired at all (drives the calm
/// empty/unavailable distinction in the UI).
final Provider<bool> plannerConfiguredProvider = Provider<bool>((Ref ref) {
  return ref.watch(plannerProfileProvider) != null &&
      ref.watch(plannerRepositoryProvider) != null &&
      ref.watch(plannerCommandServiceProvider) != null;
});

// ---------------------------------------------------------------------------
// Daily planning record view (R-PLAN-001, R-PLAN-004).
// ---------------------------------------------------------------------------

/// The editable projection of the current planning day's single area-scoped
/// record: its three named daily sections plus the composite key needed to
/// save them (R-PLAN-001, R-PLAN-004). When no record exists yet the sections
/// are empty and [record] is null; saving any section creates the record.
final class PlannerDailyView {
  const PlannerDailyView({
    required this.lifeAreaId,
    required this.periodKey,
    required this.record,
  });

  final LifeAreaId lifeAreaId;

  /// The ISO `YYYY-MM-DD` planning-day key this view edits.
  final String periodKey;

  /// The persisted record, or null when the day has no record yet.
  final PlanningPeriod? record;

  /// The `morning_plan` section body, empty when unset (R-PLAN-004).
  String get morningPlanMd => record?.morningPlanMd ?? '';

  /// The `daily_plan` section body, empty when unset.
  String get dailyPlanMd => record?.dailyPlanMd ?? '';

  /// The private `evening_reflection` section body, empty when unset.
  String get eveningReflectionMd => record?.eveningReflectionMd ?? '';

  /// Whether the day already has a persisted record.
  bool get exists => record != null;
}

/// Loads the current planning day's daily record for the default Life Area.
/// Reads run against the active local generation so the record is available
/// offline (R-GEN-001). Returns null when the stack is not wired.
final class PlannerDailyController extends AsyncNotifier<PlannerDailyView?> {
  @override
  Future<PlannerDailyView?> build() async {
    final ProfileId? profile = ref.watch(plannerProfileProvider);
    final PlannerRepository? repo = ref.watch(plannerRepositoryProvider);
    final LifeAreaId? area = ref.watch(plannerDefaultAreaProvider);
    if (profile == null || repo == null || area == null) {
      return null;
    }
    final String periodKey = ref.watch(plannerCurrentDayProvider);
    final PlanningPeriod? record = await repo.findByKey(
      profile,
      lifeAreaId: area,
      kind: PlanningPeriodKind.day,
      periodKey: periodKey,
    );
    return PlannerDailyView(
      lifeAreaId: area,
      periodKey: periodKey,
      record: record,
    );
  }

  void reload() => ref.invalidateSelf();
}

final AsyncNotifierProvider<PlannerDailyController, PlannerDailyView?>
plannerDailyProvider =
    AsyncNotifierProvider<PlannerDailyController, PlannerDailyView?>(
      PlannerDailyController.new,
    );

// ---------------------------------------------------------------------------
// Single planning-record deep link (R-PLAN-001, R-PLAN-004).
// ---------------------------------------------------------------------------

/// Loads a single planning record by its opaque id for the `/planner/<id>`
/// deep link. A record may be a day, week, or month record; the editor renders
/// only the named sections applicable to its kind. Auto-disposes when the route
/// is popped. Returns null when the stack is not wired or the id is unknown.
final plannerRecordProvider = FutureProvider.autoDispose
    .family<PlanningPeriod?, String>((Ref ref, String periodId) async {
      final ProfileId? profile = ref.watch(plannerProfileProvider);
      final PlannerRepository? repo = ref.watch(plannerRepositoryProvider);
      if (profile == null || repo == null) {
        return null;
      }
      return repo.findById(profile, PlanningPeriodId(periodId));
    });

// ---------------------------------------------------------------------------
// Transient feedback + actions controller (R-PLAN-001, R-PLAN-004).
// ---------------------------------------------------------------------------

/// Transient feedback from the most recent planner action.
sealed class PlannerFeedback {
  const PlannerFeedback();
}

final class PlannerFeedbackNone extends PlannerFeedback {
  const PlannerFeedbackNone();
}

final class PlannerFeedbackSaved extends PlannerFeedback {
  const PlannerFeedbackSaved();
}

final class PlannerFeedbackError extends PlannerFeedback {
  const PlannerFeedbackError(this.failure);
  final Failure failure;
}

const Failure _unavailableFailure = Failure(
  kind: FailureKind.unavailableCapability,
  code: 'planner.unavailable',
  safeMessageKey: 'error.capability',
  retryable: false,
);

/// Orchestrates the daily planning-record save over the durable command
/// contract. It holds no business rules; it maps the editor's save intent to a
/// [SavePlanningRecordInput] (create-or-update the single record), awaits the
/// committed result, refreshes the daily record, and exposes transient
/// feedback. It only edits the record's own free-text sections; it never
/// touches task due dates or carry-forward relations (R-PLAN-004).
final class PlannerActionsController extends Notifier<PlannerFeedback> {
  @override
  PlannerFeedback build() => const PlannerFeedbackNone();

  void dismiss() => state = const PlannerFeedbackNone();

  CommandId _id() => ref.read(plannerCommandIdFactoryProvider)();
  ProfileId? get _profile => ref.read(plannerProfileProvider);
  PlannerCommandService? get _commands =>
      ref.read(plannerCommandServiceProvider);

  bool get _wired => _commands != null && _profile != null;

  /// Creates or updates the current day's daily record, setting each named
  /// section to its edited text or clearing it when empty (sections are
  /// optional/skippable per R-PLAN-004).
  Future<bool> saveDaily({
    required LifeAreaId lifeAreaId,
    required String periodKey,
    required String morningPlanMd,
    required String dailyPlanMd,
    required String eveningReflectionMd,
  }) async {
    if (!_wired) {
      state = const PlannerFeedbackError(_unavailableFailure);
      return false;
    }
    final Result<CommittedCommandResult> result = await _commands!
        .savePlanningRecord(
          commandId: _id(),
          profileId: _profile!,
          input: SavePlanningRecordInput(
            lifeAreaId: lifeAreaId.value,
            kind: PlanningPeriodKind.day,
            periodKey: periodKey,
            morningPlanMd: _edit(morningPlanMd),
            dailyPlanMd: _edit(dailyPlanMd),
            eveningReflectionMd: _edit(eveningReflectionMd),
          ),
        );
    switch (result) {
      case Success<CommittedCommandResult>():
        ref.invalidate(plannerDailyProvider);
        state = const PlannerFeedbackSaved();
        return true;
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        state = PlannerFeedbackError(failure);
        return false;
    }
  }

  /// Creates or updates any area-scoped record addressed by its composite key,
  /// setting only the named sections applicable to [kind] (R-PLAN-001,
  /// R-PLAN-004). Backs the `/planner/<id>` deep-link editor, which may target a
  /// day, week, or month record. Unspecified sections are left unchanged.
  Future<bool> saveRecord({
    required LifeAreaId lifeAreaId,
    required PlanningPeriodKind kind,
    required String periodKey,
    String? morningPlanMd,
    String? dailyPlanMd,
    String? eveningReflectionMd,
    String? planIntentionMd,
    String? reflectionMd,
  }) async {
    if (!_wired) {
      state = const PlannerFeedbackError(_unavailableFailure);
      return false;
    }
    final Result<CommittedCommandResult> result = await _commands!
        .savePlanningRecord(
          commandId: _id(),
          profileId: _profile!,
          input: SavePlanningRecordInput(
            lifeAreaId: lifeAreaId.value,
            kind: kind,
            periodKey: periodKey,
            morningPlanMd: _editOrUnchanged(morningPlanMd),
            dailyPlanMd: _editOrUnchanged(dailyPlanMd),
            eveningReflectionMd: _editOrUnchanged(eveningReflectionMd),
            planIntentionMd: _editOrUnchanged(planIntentionMd),
            reflectionMd: _editOrUnchanged(reflectionMd),
          ),
        );
    switch (result) {
      case Success<CommittedCommandResult>():
        ref.invalidate(plannerDailyProvider);
        state = const PlannerFeedbackSaved();
        return true;
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        state = PlannerFeedbackError(failure);
        return false;
    }
  }

  /// An empty section is cleared; a non-empty one is set to its exact text so
  /// the canonical Markdown body round-trips (R-PLAN-004).
  SectionEdit _edit(String value) =>
      value.isEmpty ? SectionEdit.clear : SectionEdit.set(value);

  /// Maps a nullable edited section to a [SectionEdit]: a null value leaves the
  /// section unchanged (it does not apply to this record's kind), while any
  /// provided value is cleared when empty or set otherwise.
  SectionEdit _editOrUnchanged(String? value) =>
      value == null ? SectionEdit.unchanged : _edit(value);
}

final NotifierProvider<PlannerActionsController, PlannerFeedback>
plannerActionsProvider =
    NotifierProvider<PlannerActionsController, PlannerFeedback>(
      PlannerActionsController.new,
    );

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
