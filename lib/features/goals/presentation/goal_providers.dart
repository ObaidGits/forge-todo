import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/goals/application/goal_command_service.dart';
import 'package:forge/features/goals/application/goal_commands.dart';
import 'package:forge/features/goals/application/roadmap_command_service.dart';
import 'package:forge/features/goals/application/roadmap_commands.dart';
import 'package:forge/features/goals/domain/checklist_item.dart';
import 'package:forge/features/goals/domain/goal.dart';
import 'package:forge/features/goals/domain/goal_progress.dart';
import 'package:forge/features/goals/domain/goal_progress_mode.dart';
import 'package:forge/features/goals/domain/goal_repository.dart';
import 'package:forge/features/goals/domain/goal_status.dart';
import 'package:forge/features/goals/domain/milestone.dart';
import 'package:forge/features/goals/domain/roadmap.dart';
import 'package:forge/features/goals/domain/roadmap_progress.dart';
import 'package:forge/features/goals/domain/roadmap_repository.dart';
import 'package:forge/features/goals/domain/roadmap_section.dart';
import 'package:forge/features/goals/domain/roadmap_topic.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';

// ---------------------------------------------------------------------------
// Composition seams. Defaults keep the running app honest before the encrypted
// runtime is wired; the composition root and tests override them. The goals
// feature owns its own seams so it never imports another feature's
// presentation or infrastructure (design.md §4).
// ---------------------------------------------------------------------------

/// The active local profile, or null when no generation is open yet.
final Provider<ProfileId?> goalsProfileProvider = Provider<ProfileId?>(
  (Ref ref) => null,
);

/// The goals read contract (domain repository). Null until wired.
final Provider<GoalRepository?> goalsRepositoryProvider =
    Provider<GoalRepository?>((Ref ref) => null);

/// The roadmap read contract (domain repository). Null until wired.
final Provider<RoadmapRepository?> roadmapRepositoryProvider =
    Provider<RoadmapRepository?>((Ref ref) => null);

/// The durable goal command contract. Null until wired.
final Provider<GoalCommandService?> goalsCommandServiceProvider =
    Provider<GoalCommandService?>((Ref ref) => null);

/// The durable roadmap command contract. Null until wired.
final Provider<RoadmapCommandService?> roadmapCommandServiceProvider =
    Provider<RoadmapCommandService?>((Ref ref) => null);

/// Produces a fresh unique [CommandId] per durable command (R-GEN-005).
final Provider<CommandId Function()> goalsCommandIdFactoryProvider =
    Provider<CommandId Function()>((Ref ref) => _defaultCommandId);

/// A selectable Life Area for the goal editor. Names are decorative; the id is
/// the identifier (ux-design §5). Empty when the areas feature is not wired.
final class GoalAreaOption {
  const GoalAreaOption({required this.id, required this.name});
  final LifeAreaId id;
  final String name;
}

/// The Life Areas offered by the editor. Default empty; overridden by the app.
final Provider<List<GoalAreaOption>> goalsAreaOptionsProvider =
    Provider<List<GoalAreaOption>>((Ref ref) => const <GoalAreaOption>[]);

/// The default Life Area a newly created goal inherits (R-GEN-002). Null when
/// unavailable, in which case create is unavailable.
final Provider<LifeAreaId?> goalsDefaultAreaProvider = Provider<LifeAreaId?>((
  Ref ref,
) {
  final List<GoalAreaOption> options = ref.watch(goalsAreaOptionsProvider);
  return options.isEmpty ? null : options.first.id;
});

/// Whether the goals read stack is wired at all (used for the
/// empty/unavailable distinction in the UI).
final Provider<bool> goalsConfiguredProvider = Provider<bool>((Ref ref) {
  return ref.watch(goalsProfileProvider) != null &&
      ref.watch(goalsRepositoryProvider) != null;
});

// ---------------------------------------------------------------------------
// Goal list view state (R-GOAL-001, R-GOAL-007).
// ---------------------------------------------------------------------------

/// The currently selected goal list view. Goals are unlimited and never paid
/// gated (R-GOAL-001); Archived preserves history and links (R-GOAL-007).
final class GoalViewController extends Notifier<GoalViewKind> {
  @override
  GoalViewKind build() => GoalViewKind.active;

  void set(GoalViewKind view) {
    if (state != view) {
      state = view;
    }
  }
}

final NotifierProvider<GoalViewController, GoalViewKind> goalViewProvider =
    NotifierProvider<GoalViewController, GoalViewKind>(GoalViewController.new);

/// Loads the goals for the current view. Reads run against the active local
/// generation, so the list is always available offline (R-GEN-001).
final class GoalListController extends AsyncNotifier<List<Goal>> {
  @override
  Future<List<Goal>> build() async {
    final ProfileId? profile = ref.watch(goalsProfileProvider);
    final GoalRepository? repo = ref.watch(goalsRepositoryProvider);
    final GoalViewKind view = ref.watch(goalViewProvider);
    if (profile == null || repo == null) {
      return const <Goal>[];
    }
    return repo.view(profile, view);
  }

  void reload() => ref.invalidateSelf();
}

final AsyncNotifierProvider<GoalListController, List<Goal>> goalListProvider =
    AsyncNotifierProvider<GoalListController, List<Goal>>(
      GoalListController.new,
    );

// ---------------------------------------------------------------------------
// Goal detail projection (R-GOAL-002, R-GOAL-004).
// ---------------------------------------------------------------------------

/// The composed detail projection for one goal: its descriptive fields, ordered
/// milestones, tag ids, transparent derived-or-manual progress and whether it
/// owns a roadmap (R-GOAL-002, R-GOAL-004).
final class GoalDetailView {
  const GoalDetailView({
    required this.goal,
    required this.milestones,
    required this.tagIds,
    required this.progress,
    required this.hasRoadmap,
  });

  final Goal goal;
  final List<Milestone> milestones;
  final List<String> tagIds;

  /// The transparent progress surface: manual value, or progress derived only
  /// from roadmap topic leaves. Always exposes formula, eligible count and
  /// total weight (R-GOAL-004).
  final GoalProgress progress;

  final bool hasRoadmap;

  int get completedMilestones =>
      milestones.where((Milestone m) => m.isCompleted).length;
}

/// Loads the detail projection for a goal id. Auto-disposes when the detail
/// route is popped.
final goalDetailProvider = FutureProvider.autoDispose
    .family<GoalDetailView?, String>((Ref ref, String goalId) async {
      final ProfileId? profile = ref.watch(goalsProfileProvider);
      final GoalRepository? repo = ref.watch(goalsRepositoryProvider);
      final RoadmapRepository? roadmapRepo = ref.watch(
        roadmapRepositoryProvider,
      );
      if (profile == null || repo == null) {
        return null;
      }
      final GoalId id = GoalId(goalId);
      final Goal? goal = await repo.findById(profile, id);
      if (goal == null) {
        return null;
      }
      final List<Milestone> milestones = await repo.milestonesOf(profile, id);
      final List<String> tagIds = await repo.tagIdsFor(profile, id);
      final Roadmap? roadmap = await roadmapRepo?.findByGoal(profile, id);
      final GoalProgress progress;
      if (goal.progressMode == GoalProgressMode.manual) {
        progress = goal.manualProgressSurface;
      } else if (roadmapRepo != null) {
        progress = await roadmapRepo.deriveGoalProgress(profile, id);
      } else {
        progress = GoalProgressPolicy.derived(const <GoalProgressLeaf>[]);
      }
      return GoalDetailView(
        goal: goal,
        milestones: milestones,
        tagIds: tagIds,
        progress: progress,
        hasRoadmap: roadmap != null,
      );
    });

// ---------------------------------------------------------------------------
// Roadmap outline projection (R-GOAL-003, R-GOAL-004).
// ---------------------------------------------------------------------------

/// A topic with its checklist items, for the outline (R-GOAL-003).
final class RoadmapTopicView {
  const RoadmapTopicView({required this.topic, required this.checklist});
  final RoadmapTopic topic;
  final List<ChecklistItem> checklist;
}

/// A section with its ordered topics and its presentation-only aggregation
/// (R-GOAL-003, R-GOAL-004). Sections carry no completion weight of their own;
/// [aggregation] is a display-only aggregation of eligible descendant topic
/// weights computed through the same derived formula so it can never diverge
/// from or double-count against the roadmap total.
final class RoadmapSectionView {
  const RoadmapSectionView({
    required this.section,
    required this.topics,
    required this.aggregation,
  });
  final RoadmapSection section;
  final List<RoadmapTopicView> topics;
  final GoalProgress aggregation;
}

/// The composed roadmap outline for one goal (R-GOAL-003, R-GOAL-004).
final class RoadmapOutline {
  const RoadmapOutline({
    required this.goal,
    required this.roadmap,
    required this.sections,
    required this.progress,
  });

  final Goal goal;

  /// The goal's single roadmap, or null when it has none (R-GOAL-001).
  final Roadmap? roadmap;

  final List<RoadmapSectionView> sections;

  /// The whole-roadmap derived progress (R-GOAL-004).
  final GoalProgress progress;

  bool get hasRoadmap => roadmap != null;
}

/// Loads the roadmap outline for a goal id. Auto-disposes when the route pops.
final roadmapOutlineProvider = FutureProvider.autoDispose
    .family<RoadmapOutline?, String>((Ref ref, String goalId) async {
      final ProfileId? profile = ref.watch(goalsProfileProvider);
      final GoalRepository? goalRepo = ref.watch(goalsRepositoryProvider);
      final RoadmapRepository? repo = ref.watch(roadmapRepositoryProvider);
      if (profile == null || goalRepo == null || repo == null) {
        return null;
      }
      final GoalId id = GoalId(goalId);
      final Goal? goal = await goalRepo.findById(profile, id);
      if (goal == null) {
        return null;
      }
      final Roadmap? roadmap = await repo.findByGoal(profile, id);
      if (roadmap == null) {
        return RoadmapOutline(
          goal: goal,
          roadmap: null,
          sections: const <RoadmapSectionView>[],
          progress: RoadmapProgressPolicy.forRoadmap(const <RoadmapTopic>[]),
        );
      }
      final List<RoadmapSection> sections = await repo.sectionsOf(
        profile,
        roadmap.id,
      );
      final List<RoadmapTopic> allTopics = <RoadmapTopic>[];
      final List<RoadmapSectionView> sectionViews = <RoadmapSectionView>[];
      for (final RoadmapSection section in sections) {
        final List<RoadmapTopic> topics = await repo.topicsOfSection(
          profile,
          section.id,
        );
        allTopics.addAll(topics);
        final List<RoadmapTopicView> topicViews = <RoadmapTopicView>[];
        for (final RoadmapTopic topic in topics) {
          final List<ChecklistItem> checklist = await repo.checklistItemsOf(
            profile,
            topic.id,
          );
          topicViews.add(RoadmapTopicView(topic: topic, checklist: checklist));
        }
        sectionViews.add(
          RoadmapSectionView(
            section: section,
            topics: topicViews,
            aggregation: RoadmapProgressPolicy.forSection(topics),
          ),
        );
      }
      return RoadmapOutline(
        goal: goal,
        roadmap: roadmap,
        sections: sectionViews,
        progress: RoadmapProgressPolicy.forRoadmap(allTopics),
      );
    });

// ---------------------------------------------------------------------------
// Transient feedback (Undo / error / milestone celebration).
// ---------------------------------------------------------------------------

/// A reversible action offered as immediate Undo (R-GEN-003).
final class GoalUndo {
  const GoalUndo({required this.messageCode, required this.undo});
  final String messageCode;
  final Future<Result<CommittedCommandResult>> Function() undo;
}

/// Transient feedback from the most recent goal/roadmap action.
sealed class GoalFeedback {
  const GoalFeedback();
}

final class GoalFeedbackNone extends GoalFeedback {
  const GoalFeedbackNone();
}

final class GoalFeedbackUndo extends GoalFeedback {
  const GoalFeedbackUndo(this.offer);
  final GoalUndo offer;
}

final class GoalFeedbackError extends GoalFeedback {
  const GoalFeedbackError(this.failure);
  final Failure failure;
}

/// A subtle, dismissible milestone celebration (R-GOAL-006). It carries only
/// the milestone title; the view honours reduced-motion when rendering it.
final class GoalFeedbackCelebrate extends GoalFeedback {
  const GoalFeedbackCelebrate(this.milestoneTitle);
  final String milestoneTitle;
}

const Failure _unavailableFailure = Failure(
  kind: FailureKind.unavailableCapability,
  code: 'goals.unavailable',
  safeMessageKey: 'error.capability',
  retryable: false,
);

// ---------------------------------------------------------------------------
// Goal actions controller (R-GOAL-001, R-GOAL-002, R-GOAL-006, R-GOAL-007).
// ---------------------------------------------------------------------------

/// Orchestrates goal + milestone mutations over the durable command contracts.
/// It holds no business rules; it maps a UI intent to a command, awaits the
/// committed result, refreshes affected providers, and exposes transient
/// feedback (Undo, error, or a milestone celebration).
final class GoalActionsController extends Notifier<GoalFeedback> {
  @override
  GoalFeedback build() => const GoalFeedbackNone();

  void dismiss() => state = const GoalFeedbackNone();

  CommandId _id() => ref.read(goalsCommandIdFactoryProvider)();
  ProfileId? get _profile => ref.read(goalsProfileProvider);
  GoalCommandService? get _commands => ref.read(goalsCommandServiceProvider);

  bool get _wired => _commands != null && _profile != null;

  void _refreshList() => ref.invalidate(goalListProvider);
  void _refreshDetail(String goalId) =>
      ref.invalidate(goalDetailProvider(goalId));

  /// Creates a goal and returns its generated id, or null on failure
  /// (R-GOAL-001, R-GOAL-002).
  Future<String?> create({
    required String title,
    required LifeAreaId lifeAreaId,
    String outcomeMd = '',
    GoalStatus status = GoalStatus.active,
    String? targetDate,
    GoalProgressMode progressMode = GoalProgressMode.manual,
    double? manualProgress = 0,
  }) async {
    if (!_wired) {
      state = const GoalFeedbackError(_unavailableFailure);
      return null;
    }
    final Result<CommittedCommandResult> result = await _commands!.create(
      commandId: _id(),
      profileId: _profile!,
      input: CreateGoalInput(
        lifeAreaId: lifeAreaId,
        title: title,
        outcomeMd: outcomeMd,
        status: status,
        targetDate: targetDate,
        progressMode: progressMode,
        manualProgress: progressMode == GoalProgressMode.derived
            ? null
            : manualProgress,
      ),
    );
    switch (result) {
      case Success<CommittedCommandResult>(
        value: final CommittedCommandResult r,
      ):
        _refreshList();
        state = const GoalFeedbackNone();
        return _idFromPayload(r);
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        state = GoalFeedbackError(failure);
        return null;
    }
  }

  /// Patches a goal's descriptive fields (R-GOAL-002).
  Future<bool> update(String goalId, UpdateGoalInput input) async {
    return _mutate(
      goalId,
      () => _commands!.update(
        commandId: _id(),
        profileId: _profile!,
        goalId: GoalId(goalId),
        input: input,
      ),
    );
  }

  /// Sets a goal's lifecycle status (R-GOAL-002).
  Future<bool> setStatus(String goalId, GoalStatus status) async {
    return _mutate(
      goalId,
      () => _commands!.setStatus(
        commandId: _id(),
        profileId: _profile!,
        goalId: GoalId(goalId),
        status: status,
      ),
    );
  }

  /// Updates a manual goal's clamped `0..1` progress value (R-GOAL-004).
  Future<bool> setManualProgress(String goalId, double value) async {
    return _mutate(
      goalId,
      () => _commands!.setManualProgress(
        commandId: _id(),
        profileId: _profile!,
        goalId: GoalId(goalId),
        value: value,
      ),
    );
  }

  /// Switches a goal between manual and derived progress (R-GOAL-004).
  Future<bool> setProgressPolicy(
    String goalId,
    GoalProgressMode mode, {
    double? manualValue,
  }) async {
    return _mutate(
      goalId,
      () => _commands!.setProgressPolicy(
        commandId: _id(),
        profileId: _profile!,
        goalId: GoalId(goalId),
        input: SetProgressPolicyInput(mode: mode, manualValue: manualValue),
      ),
    );
  }

  /// Archives or unarchives a goal, preserving all history and links
  /// (R-GOAL-007). Offers Undo.
  Future<bool> setArchived(String goalId, {required bool archived}) async {
    if (!_wired) {
      state = const GoalFeedbackError(_unavailableFailure);
      return false;
    }
    final Result<CommittedCommandResult> result = await _commands!.setArchived(
      commandId: _id(),
      profileId: _profile!,
      goalId: GoalId(goalId),
      archived: archived,
    );
    switch (result) {
      case Success<CommittedCommandResult>():
        _refreshList();
        _refreshDetail(goalId);
        state = GoalFeedbackUndo(
          GoalUndo(
            messageCode: archived ? 'archived' : 'unarchived',
            undo: () async {
              final Result<CommittedCommandResult> undo = await _commands!
                  .setArchived(
                    commandId: _id(),
                    profileId: _profile!,
                    goalId: GoalId(goalId),
                    archived: !archived,
                  );
              _refreshList();
              _refreshDetail(goalId);
              return undo;
            },
          ),
        );
        return true;
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        state = GoalFeedbackError(failure);
        return false;
    }
  }

  /// Adds a milestone to a goal (R-GOAL-002).
  Future<bool> addMilestone(
    String goalId, {
    required String title,
    String? targetDate,
  }) async {
    return _mutate(
      goalId,
      () => _commands!.addMilestone(
        commandId: _id(),
        profileId: _profile!,
        goalId: GoalId(goalId),
        input: CreateMilestoneInput(title: title, targetDate: targetDate),
      ),
    );
  }

  /// Completes a milestone, appending completion history, and raises a subtle
  /// celebration (R-GOAL-006).
  Future<bool> completeMilestone(
    String goalId,
    String milestoneId,
    String milestoneTitle,
  ) async {
    if (!_wired) {
      state = const GoalFeedbackError(_unavailableFailure);
      return false;
    }
    final Result<CommittedCommandResult> result = await _commands!
        .completeMilestone(
          commandId: _id(),
          profileId: _profile!,
          milestoneId: MilestoneId(milestoneId),
        );
    switch (result) {
      case Success<CommittedCommandResult>():
        _refreshDetail(goalId);
        state = GoalFeedbackCelebrate(milestoneTitle);
        return true;
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        state = GoalFeedbackError(failure);
        return false;
    }
  }

  /// Reverses a milestone completion; prior history remains in the append-only
  /// activity feed (R-GOAL-006).
  Future<bool> uncompleteMilestone(String goalId, String milestoneId) async {
    return _mutate(
      goalId,
      () => _commands!.uncompleteMilestone(
        commandId: _id(),
        profileId: _profile!,
        milestoneId: MilestoneId(milestoneId),
      ),
    );
  }

  Future<bool> _mutate(
    String goalId,
    Future<Result<CommittedCommandResult>> Function() run,
  ) async {
    if (!_wired) {
      state = const GoalFeedbackError(_unavailableFailure);
      return false;
    }
    final Result<CommittedCommandResult> result = await run();
    switch (result) {
      case Success<CommittedCommandResult>():
        _refreshList();
        _refreshDetail(goalId);
        state = const GoalFeedbackNone();
        return true;
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        state = GoalFeedbackError(failure);
        return false;
    }
  }
}

final NotifierProvider<GoalActionsController, GoalFeedback>
goalActionsProvider = NotifierProvider<GoalActionsController, GoalFeedback>(
  GoalActionsController.new,
);

// ---------------------------------------------------------------------------
// Roadmap actions controller (R-GOAL-003, R-GOAL-004, R-GOAL-005).
// ---------------------------------------------------------------------------

/// Orchestrates roadmap tree mutations (create roadmap, sections, topics,
/// checklist, status, reorder, and rebalance) over the durable command
/// contract. Reordering is always available through explicit move
/// alternatives, never drag-only (R-GOAL-005; ux-design §4).
final class RoadmapActionsController extends Notifier<GoalFeedback> {
  @override
  GoalFeedback build() => const GoalFeedbackNone();

  void dismiss() => state = const GoalFeedbackNone();

  CommandId _id() => ref.read(goalsCommandIdFactoryProvider)();
  ProfileId? get _profile => ref.read(goalsProfileProvider);
  RoadmapCommandService? get _commands =>
      ref.read(roadmapCommandServiceProvider);

  bool get _wired => _commands != null && _profile != null;

  void _refresh(String goalId) =>
      ref.invalidate(roadmapOutlineProvider(goalId));

  /// Creates the goal's single roadmap (R-GOAL-001, R-GOAL-003).
  Future<bool> createRoadmap(String goalId, {required String title}) {
    return _run(
      goalId,
      () => _commands!.createRoadmap(
        commandId: _id(),
        profileId: _profile!,
        goalId: GoalId(goalId),
        input: CreateRoadmapInput(title: title),
      ),
    );
  }

  Future<bool> addSection(
    String goalId,
    String roadmapId, {
    required String title,
  }) {
    return _run(
      goalId,
      () => _commands!.addSection(
        commandId: _id(),
        profileId: _profile!,
        roadmapId: RoadmapId(roadmapId),
        input: CreateSectionInput(title: title),
      ),
    );
  }

  Future<bool> addTopic(
    String goalId,
    String sectionId, {
    required String title,
    num? weight,
  }) {
    return _run(
      goalId,
      () => _commands!.addTopic(
        commandId: _id(),
        profileId: _profile!,
        sectionId: RoadmapSectionId(sectionId),
        input: CreateTopicInput(title: title, weight: weight),
      ),
    );
  }

  Future<bool> setTopicStatus(
    String goalId,
    String topicId,
    RoadmapTopicStatus status,
  ) {
    return _run(
      goalId,
      () => _commands!.setTopicStatus(
        commandId: _id(),
        profileId: _profile!,
        topicId: RoadmapTopicId(topicId),
        status: status,
      ),
    );
  }

  Future<bool> setTopicWeight(String goalId, String topicId, num? weight) {
    return _run(
      goalId,
      () => _commands!.updateTopic(
        commandId: _id(),
        profileId: _profile!,
        topicId: RoadmapTopicId(topicId),
        input: UpdateTopicInput(weight: Opt<num?>(weight)),
      ),
    );
  }

  Future<bool> addChecklistItem(
    String goalId,
    String topicId, {
    required String text,
  }) {
    return _run(
      goalId,
      () => _commands!.addChecklistItem(
        commandId: _id(),
        profileId: _profile!,
        topicId: RoadmapTopicId(topicId),
        input: CreateChecklistItemInput(text: text),
      ),
    );
  }

  Future<bool> setChecklistChecked(
    String goalId,
    String itemId, {
    required bool checked,
  }) {
    return _run(
      goalId,
      () => _commands!.setChecklistItemChecked(
        commandId: _id(),
        profileId: _profile!,
        itemId: ChecklistItemId(itemId),
        checked: checked,
      ),
    );
  }

  // ---- reorder alternatives (R-GOAL-005) ---------------------------------

  /// Moves the section at [index] within [ordered] up one position. A no-op at
  /// the top. Placement uses the neighbour ranks so the move never rewrites
  /// unrelated rows (R-GOAL-005).
  Future<bool> moveSectionUp(
    String goalId,
    List<RoadmapSection> ordered,
    int index,
  ) {
    if (index <= 0) {
      return Future<bool>.value(false);
    }
    final MoveInput move = MoveInput(
      beforeRank: index - 2 >= 0 ? ordered[index - 2].rank : null,
      afterRank: ordered[index - 1].rank,
    );
    return _run(
      goalId,
      () => _commands!.moveSection(
        commandId: _id(),
        profileId: _profile!,
        sectionId: ordered[index].id,
        input: move,
      ),
    );
  }

  /// Moves the section at [index] within [ordered] down one position. A no-op
  /// at the bottom.
  Future<bool> moveSectionDown(
    String goalId,
    List<RoadmapSection> ordered,
    int index,
  ) {
    if (index >= ordered.length - 1) {
      return Future<bool>.value(false);
    }
    final MoveInput move = MoveInput(
      beforeRank: ordered[index + 1].rank,
      afterRank: index + 2 < ordered.length ? ordered[index + 2].rank : null,
    );
    return _run(
      goalId,
      () => _commands!.moveSection(
        commandId: _id(),
        profileId: _profile!,
        sectionId: ordered[index].id,
        input: move,
      ),
    );
  }

  /// Moves the topic at [index] within its section [ordered] up one position.
  Future<bool> moveTopicUp(
    String goalId,
    List<RoadmapTopic> ordered,
    int index,
  ) {
    if (index <= 0) {
      return Future<bool>.value(false);
    }
    final MoveInput move = MoveInput(
      beforeRank: index - 2 >= 0 ? ordered[index - 2].rank : null,
      afterRank: ordered[index - 1].rank,
    );
    return _run(
      goalId,
      () => _commands!.moveTopic(
        commandId: _id(),
        profileId: _profile!,
        topicId: ordered[index].id,
        input: move,
      ),
    );
  }

  /// Moves the topic at [index] within its section [ordered] down one position.
  Future<bool> moveTopicDown(
    String goalId,
    List<RoadmapTopic> ordered,
    int index,
  ) {
    if (index >= ordered.length - 1) {
      return Future<bool>.value(false);
    }
    final MoveInput move = MoveInput(
      beforeRank: ordered[index + 1].rank,
      afterRank: index + 2 < ordered.length ? ordered[index + 2].rank : null,
    );
    return _run(
      goalId,
      () => _commands!.moveTopic(
        commandId: _id(),
        profileId: _profile!,
        topicId: ordered[index].id,
        input: move,
      ),
    );
  }

  /// Rebalances all section ranks in a roadmap as one sync-safe group
  /// (R-GOAL-005).
  Future<bool> rebalanceSections(String goalId, String roadmapId) {
    return _run(
      goalId,
      () => _commands!.rebalanceSections(
        commandId: _id(),
        profileId: _profile!,
        roadmapId: RoadmapId(roadmapId),
      ),
    );
  }

  /// Rebalances all topic ranks in a section as one sync-safe group
  /// (R-GOAL-005).
  Future<bool> rebalanceTopics(String goalId, String sectionId) {
    return _run(
      goalId,
      () => _commands!.rebalanceTopics(
        commandId: _id(),
        profileId: _profile!,
        sectionId: RoadmapSectionId(sectionId),
      ),
    );
  }

  Future<bool> _run(
    String goalId,
    Future<Result<CommittedCommandResult>> Function() run,
  ) async {
    if (!_wired) {
      state = const GoalFeedbackError(_unavailableFailure);
      return false;
    }
    final Result<CommittedCommandResult> result = await run();
    switch (result) {
      case Success<CommittedCommandResult>():
        _refresh(goalId);
        // The whole goal's progress can change with topic edits, so refresh the
        // detail too when it is being observed.
        ref.invalidate(goalDetailProvider(goalId));
        state = const GoalFeedbackNone();
        return true;
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        state = GoalFeedbackError(failure);
        return false;
    }
  }
}

final NotifierProvider<RoadmapActionsController, GoalFeedback>
roadmapActionsProvider =
    NotifierProvider<RoadmapActionsController, GoalFeedback>(
      RoadmapActionsController.new,
    );

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

String? _idFromPayload(CommittedCommandResult result) {
  final String? payload = result.resultPayload;
  if (payload == null) {
    return null;
  }
  final Object? decoded = jsonDecode(payload);
  if (decoded is Map<String, Object?>) {
    return decoded['id'] as String?;
  }
  return null;
}

final Random _random = Random();

CommandId _defaultCommandId() {
  final int micros = DateTime.now().toUtc().microsecondsSinceEpoch;
  final String salt = _random.nextInt(1 << 32).toRadixString(16);
  return CommandId('cmd-$micros-$salt');
}
