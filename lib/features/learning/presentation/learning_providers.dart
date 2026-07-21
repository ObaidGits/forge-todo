import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/learning/application/learning_command_service.dart';
import 'package:forge/features/learning/application/learning_commands.dart';
import 'package:forge/features/learning/domain/learning_item.dart';
import 'package:forge/features/learning/domain/learning_policies.dart';
import 'package:forge/features/learning/domain/learning_repository.dart';
import 'package:forge/features/learning/domain/learning_resource.dart';
import 'package:forge/features/learning/domain/learning_resource_type.dart';
import 'package:forge/features/learning/domain/study_session.dart';

// ---------------------------------------------------------------------------
// Composition seams. Defaults keep the running app honest before the encrypted
// runtime is wired; the composition root and tests override them. The learning
// feature owns its own seams so its presentation never imports another
// feature's presentation nor its own infrastructure (design.md §4/§16). It
// depends only on the domain [LearningRepository] read contract and the
// [LearningCommandService] write contract, never a concrete repository.
// ---------------------------------------------------------------------------

/// The active local profile, or null when no generation is open yet.
final Provider<ProfileId?> learningProfileProvider = Provider<ProfileId?>(
  (Ref ref) => null,
);

/// The learning read contract (domain repository). Null until wired.
final Provider<LearningRepository?> learningRepositoryProvider =
    Provider<LearningRepository?>((Ref ref) => null);

/// The durable learning command contract. Null until wired.
final Provider<LearningCommandService?> learningCommandServiceProvider =
    Provider<LearningCommandService?>((Ref ref) => null);

/// Trusted UTC clock used to stamp study-session start/stop instants and item
/// completion (R-LEARN-002, R-LEARN-004).
final Provider<Clock> learningClockProvider = Provider<Clock>(
  (Ref ref) => const _SystemUtcClock(),
);

/// The default Life Area a newly created Learning Resource inherits
/// (R-GEN-002). Null when unavailable, in which case create is unavailable.
final Provider<LifeAreaId?> learningDefaultAreaProvider = Provider<LifeAreaId?>(
  (Ref ref) => null,
);

/// Produces a fresh unique [CommandId] per durable command (R-GEN-005).
final Provider<CommandId Function()> learningCommandIdFactoryProvider =
    Provider<CommandId Function()>((Ref ref) => _defaultCommandId);

/// Whether the learning read stack is wired at all (drives the calm
/// empty/unavailable distinction in the UI).
final Provider<bool> learningConfiguredProvider = Provider<bool>((Ref ref) {
  return ref.watch(learningProfileProvider) != null &&
      ref.watch(learningRepositoryProvider) != null;
});

// ---------------------------------------------------------------------------
// Learning list view state (R-LEARN-001, R-LEARN-004).
// ---------------------------------------------------------------------------

/// A Learning Resource plus its transparent derived-or-manual progress, for the
/// list surface (R-LEARN-001, R-LEARN-004).
final class LearningResourceView {
  const LearningResourceView({required this.resource, required this.progress});

  final LearningResource resource;
  final LearningProgress progress;
}

/// Loads the Learning Resources for the active profile with their progress.
/// Reads run against the active local generation so the list is available
/// offline (R-GEN-001).
final class LearningListController
    extends AsyncNotifier<List<LearningResourceView>> {
  @override
  Future<List<LearningResourceView>> build() async {
    final ProfileId? profile = ref.watch(learningProfileProvider);
    final LearningRepository? repo = ref.watch(learningRepositoryProvider);
    if (profile == null || repo == null) {
      return const <LearningResourceView>[];
    }
    final List<LearningResource> resources = await repo.listResources(profile);
    final List<LearningResourceView> views = <LearningResourceView>[];
    for (final LearningResource resource in resources) {
      final LearningProgress progress = await repo.progressOf(
        profile,
        resource.id,
      );
      views.add(LearningResourceView(resource: resource, progress: progress));
    }
    return views;
  }

  void reload() => ref.invalidateSelf();
}

final AsyncNotifierProvider<LearningListController, List<LearningResourceView>>
learningListProvider =
    AsyncNotifierProvider<LearningListController, List<LearningResourceView>>(
      LearningListController.new,
    );

// ---------------------------------------------------------------------------
// Learning resource detail projection (R-LEARN-001..004).
// ---------------------------------------------------------------------------

/// The composed detail projection for one Learning Resource: the resource, its
/// ordered items, transparent progress, the read-only resume point, and the
/// current (non-superseded) study sessions (R-LEARN-001..004).
final class LearningResourceDetail {
  const LearningResourceDetail({
    required this.resource,
    required this.items,
    required this.progress,
    required this.resume,
    required this.sessions,
  });

  final LearningResource resource;
  final List<LearningItem> items;
  final LearningProgress progress;
  final ResumePoint resume;
  final List<StudySession> sessions;
}

/// Loads the detail projection for a resource id. Auto-disposes when the detail
/// route is popped.
final learningResourceDetailProvider = FutureProvider.autoDispose
    .family<LearningResourceDetail?, String>((
      Ref ref,
      String resourceId,
    ) async {
      final ProfileId? profile = ref.watch(learningProfileProvider);
      final LearningRepository? repo = ref.watch(learningRepositoryProvider);
      if (profile == null || repo == null) {
        return null;
      }
      final LearningResourceId id = LearningResourceId(resourceId);
      final LearningResource? resource = await repo.findResource(profile, id);
      if (resource == null) {
        return null;
      }
      final List<LearningItem> items = await repo.itemsOf(profile, id);
      final LearningProgress progress = await repo.progressOf(profile, id);
      final ResumePoint resume = await repo.resumePoint(profile, id);
      final List<StudySession> sessions = await repo.currentSessionsOf(
        profile,
        id,
      );
      return LearningResourceDetail(
        resource: resource,
        items: items,
        progress: progress,
        resume: resume,
        sessions: sessions,
      );
    });

// ---------------------------------------------------------------------------
// Study-session timer (R-LEARN-002).
// ---------------------------------------------------------------------------

/// The id of the Learning Resource the user is currently timing a study session
/// for, or null when no timer is running. Study sessions are logged with an
/// explicit start and end instant, so the "start" is tracked locally until the
/// user stops and the session is durably logged through the command service
/// (R-LEARN-002). The observable state is the running resource id so views can
/// react; the start instant is held privately for the eventual log.
final class LearningStudyTimerController extends Notifier<String?> {
  int? _startedAtUtc;

  @override
  String? build() => null;

  bool isRunningFor(String resourceId) =>
      state == resourceId && _startedAtUtc != null;

  void start(String resourceId) {
    _startedAtUtc = ref
        .read(learningClockProvider)
        .utcNow()
        .microsecondsSinceEpoch;
    state = resourceId;
  }

  /// Stops the timer and returns the start instant (UTC microseconds), or null
  /// when no timer was running.
  int? stop() {
    final int? started = _startedAtUtc;
    _startedAtUtc = null;
    state = null;
    return started;
  }
}

final NotifierProvider<LearningStudyTimerController, String?>
learningStudyTimerProvider =
    NotifierProvider<LearningStudyTimerController, String?>(
      LearningStudyTimerController.new,
    );

// ---------------------------------------------------------------------------
// Transient feedback + actions controller (R-LEARN-001, R-LEARN-002,
// R-LEARN-004).
// ---------------------------------------------------------------------------

/// Transient feedback from the most recent learning action.
sealed class LearningFeedback {
  const LearningFeedback();
}

final class LearningFeedbackNone extends LearningFeedback {
  const LearningFeedbackNone();
}

final class LearningFeedbackError extends LearningFeedback {
  const LearningFeedbackError(this.failure);
  final Failure failure;
}

const Failure _unavailableFailure = Failure(
  kind: FailureKind.unavailableCapability,
  code: 'learning.unavailable',
  safeMessageKey: 'error.capability',
  retryable: false,
);

/// Orchestrates Learning Resource + item + study-session mutations over the
/// durable command contract. It holds no business rules; it maps a UI intent to
/// a command, awaits the committed result, refreshes affected providers, and
/// exposes transient error feedback.
final class LearningActionsController extends Notifier<LearningFeedback> {
  @override
  LearningFeedback build() => const LearningFeedbackNone();

  void dismiss() => state = const LearningFeedbackNone();

  CommandId _id() => ref.read(learningCommandIdFactoryProvider)();
  ProfileId? get _profile => ref.read(learningProfileProvider);
  LearningCommandService? get _commands =>
      ref.read(learningCommandServiceProvider);
  int get _now =>
      ref.read(learningClockProvider).utcNow().microsecondsSinceEpoch;

  bool get _wired => _commands != null && _profile != null;

  void _refreshList() => ref.invalidate(learningListProvider);
  void _refreshDetail(String resourceId) =>
      ref.invalidate(learningResourceDetailProvider(resourceId));

  /// Creates a Learning Resource and returns its generated id, or null on
  /// failure (R-LEARN-001).
  Future<String?> create({
    required String title,
    required LearningResourceType type,
    required LifeAreaId lifeAreaId,
  }) async {
    if (!_wired) {
      state = const LearningFeedbackError(_unavailableFailure);
      return null;
    }
    final Result<CommittedCommandResult> result = await _commands!
        .createResource(
          commandId: _id(),
          profileId: _profile!,
          input: CreateResourceInput(
            lifeAreaId: lifeAreaId.value,
            title: title,
            type: type,
          ),
        );
    switch (result) {
      case Success<CommittedCommandResult>(
        value: final CommittedCommandResult r,
      ):
        _refreshList();
        state = const LearningFeedbackNone();
        return _resourceIdFromPayload(r);
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        state = LearningFeedbackError(failure);
        return null;
    }
  }

  /// Marks an item complete at the current instant (R-LEARN-004).
  Future<bool> completeItem(String resourceId, String itemId) async {
    return _mutate(
      resourceId,
      () => _commands!.completeItem(
        commandId: _id(),
        profileId: _profile!,
        itemId: itemId,
        completedAtUtc: _now,
      ),
    );
  }

  /// Clears an item's completion (R-LEARN-004).
  Future<bool> reopenItem(String resourceId, String itemId) async {
    return _mutate(
      resourceId,
      () => _commands!.reopenItem(
        commandId: _id(),
        profileId: _profile!,
        itemId: itemId,
      ),
    );
  }

  /// Starts timing a study session for [resourceId]. Nothing is persisted until
  /// [stopStudySession] logs the completed session (R-LEARN-002).
  void startStudySession(String resourceId) {
    ref.read(learningStudyTimerProvider.notifier).start(resourceId);
    state = const LearningFeedbackNone();
  }

  /// Stops the running study timer for [resourceId] and durably logs the
  /// completed session from its start to now (R-LEARN-002). Optionally names the
  /// studied [itemId] so the resume point tracks it (R-LEARN-003).
  Future<bool> stopStudySession(String resourceId, {String? itemId}) async {
    final int? startedAtUtc = ref
        .read(learningStudyTimerProvider.notifier)
        .stop();
    if (startedAtUtc == null) {
      return false;
    }
    if (!_wired) {
      state = const LearningFeedbackError(_unavailableFailure);
      return false;
    }
    final int endedAtUtc = _now;
    final Result<CommittedCommandResult> result = await _commands!
        .logStudySession(
          commandId: _id(),
          profileId: _profile!,
          input: LogStudySessionInput(
            resourceId: resourceId,
            startedAtUtc: startedAtUtc,
            endedAtUtc: endedAtUtc < startedAtUtc ? startedAtUtc : endedAtUtc,
            itemId: itemId,
          ),
        );
    switch (result) {
      case Success<CommittedCommandResult>():
        _refreshDetail(resourceId);
        _refreshList();
        state = const LearningFeedbackNone();
        return true;
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        state = LearningFeedbackError(failure);
        return false;
    }
  }

  Future<bool> _mutate(
    String resourceId,
    Future<Result<CommittedCommandResult>> Function() run,
  ) async {
    if (!_wired) {
      state = const LearningFeedbackError(_unavailableFailure);
      return false;
    }
    final Result<CommittedCommandResult> result = await run();
    switch (result) {
      case Success<CommittedCommandResult>():
        _refreshDetail(resourceId);
        _refreshList();
        state = const LearningFeedbackNone();
        return true;
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        state = LearningFeedbackError(failure);
        return false;
    }
  }
}

final NotifierProvider<LearningActionsController, LearningFeedback>
learningActionsProvider =
    NotifierProvider<LearningActionsController, LearningFeedback>(
      LearningActionsController.new,
    );

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

String? _resourceIdFromPayload(CommittedCommandResult result) {
  final String? payload = result.resultPayload;
  if (payload == null) {
    return null;
  }
  // The create command returns `{"resource_id":"..."}`; parse it without a full
  // JSON codec dependency to keep the seam light.
  final RegExpMatch? match = RegExp(
    r'"resource_id"\s*:\s*"([^"]+)"',
  ).firstMatch(payload);
  return match?.group(1);
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
