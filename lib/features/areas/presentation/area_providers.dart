import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/areas/application/life_area_command_service.dart';
import 'package:forge/features/areas/application/life_area_commands.dart';
import 'package:forge/features/areas/application/life_area_query_service.dart';

// ---------------------------------------------------------------------------
// Composition seams. Defaults keep the running app safe and honest before the
// encrypted runtime is wired; the composition root and tests override them. The
// areas feature owns its own seams so it never imports another feature's
// presentation or infrastructure (design.md §4).
// ---------------------------------------------------------------------------

/// The active local profile, or null when no generation is open yet.
final Provider<ProfileId?> areasProfileProvider = Provider<ProfileId?>(
  (Ref ref) => null,
);

/// The areas feature's exported read contract. Null until wired.
final Provider<LifeAreaQueryService?> lifeAreaQueryServiceProvider =
    Provider<LifeAreaQueryService?>((Ref ref) => null);

/// The durable Life Area command contract. Null until wired.
final Provider<LifeAreaCommandService?> lifeAreaCommandServiceProvider =
    Provider<LifeAreaCommandService?>((Ref ref) => null);

/// Produces a fresh unique [CommandId] per durable command (R-GEN-005).
final Provider<CommandId Function()> areasCommandIdFactoryProvider =
    Provider<CommandId Function()>((Ref ref) => _defaultCommandId);

/// Whether the areas read stack is wired at all (used for the
/// empty/unavailable distinction in the UI).
final Provider<bool> areasConfiguredProvider = Provider<bool>((Ref ref) {
  return ref.watch(areasProfileProvider) != null &&
      ref.watch(lifeAreaQueryServiceProvider) != null;
});

// ---------------------------------------------------------------------------
// Life Area list (R-GEN-002).
// ---------------------------------------------------------------------------

/// Loads every Life Area for the active profile, ordered by rank. Reads run
/// against the active local generation, so the list is available offline
/// (R-GEN-001). Archived areas are included so they can be restored.
final class LifeAreaListController
    extends AsyncNotifier<List<LifeAreaSummary>> {
  @override
  Future<List<LifeAreaSummary>> build() async {
    final ProfileId? profile = ref.watch(areasProfileProvider);
    final LifeAreaQueryService? query = ref.watch(lifeAreaQueryServiceProvider);
    if (profile == null || query == null) {
      return const <LifeAreaSummary>[];
    }
    return query.list(profile);
  }

  void reload() => ref.invalidateSelf();
}

final AsyncNotifierProvider<LifeAreaListController, List<LifeAreaSummary>>
lifeAreaListProvider =
    AsyncNotifierProvider<LifeAreaListController, List<LifeAreaSummary>>(
      LifeAreaListController.new,
    );

// ---------------------------------------------------------------------------
// Mutating actions + feedback (R-GEN-002).
// ---------------------------------------------------------------------------

/// Transient feedback from the most recent Life Area action.
sealed class AreaFeedback {
  const AreaFeedback();
}

final class AreaFeedbackNone extends AreaFeedback {
  const AreaFeedbackNone();
}

/// A confirmation keyed by a stable message code the view localizes.
final class AreaFeedbackMessage extends AreaFeedback {
  const AreaFeedbackMessage(this.messageCode);
  final String messageCode;
}

final class AreaFeedbackError extends AreaFeedback {
  const AreaFeedbackError(this.failure);
  final Failure failure;
}

const Failure _unavailableFailure = Failure(
  kind: FailureKind.unavailableCapability,
  code: 'areas.unavailable',
  safeMessageKey: 'error.capability',
  retryable: false,
);

/// Orchestrates Life Area create/rename/reorder/archive over the durable
/// command contract, then refreshes the list. It holds no business rules; all
/// area semantics live in the domain and the command service.
final class AreaActionsController extends Notifier<AreaFeedback> {
  @override
  AreaFeedback build() => const AreaFeedbackNone();

  void dismiss() => state = const AreaFeedbackNone();

  CommandId _id() => ref.read(areasCommandIdFactoryProvider)();
  ProfileId? get _profile => ref.read(areasProfileProvider);
  LifeAreaCommandService? get _commands =>
      ref.read(lifeAreaCommandServiceProvider);

  bool get _wired => _commands != null && _profile != null;

  Future<bool> create({required String name, bool makeDefault = false}) => _run(
    'areaCreated',
    () => _commands!.create(
      commandId: _id(),
      profileId: _profile!,
      input: CreateLifeAreaInput(name: name, makeDefault: makeDefault),
    ),
  );

  Future<bool> rename({required String areaId, required String name}) => _run(
    'areaRenamed',
    () => _commands!.rename(
      commandId: _id(),
      profileId: _profile!,
      areaId: LifeAreaId(areaId),
      input: RenameLifeAreaInput(name: name),
    ),
  );

  Future<bool> reorder({
    required String areaId,
    String? beforeRank,
    String? afterRank,
  }) => _run(
    'areaReordered',
    () => _commands!.reorder(
      commandId: _id(),
      profileId: _profile!,
      areaId: LifeAreaId(areaId),
      input: ReorderLifeAreaInput(beforeRank: beforeRank, afterRank: afterRank),
    ),
  );

  Future<bool> archive(String areaId) => _run(
    'areaArchived',
    () => _commands!.archive(
      commandId: _id(),
      profileId: _profile!,
      areaId: LifeAreaId(areaId),
    ),
  );

  Future<bool> restore(String areaId) => _run(
    'areaRestored',
    () => _commands!.restore(
      commandId: _id(),
      profileId: _profile!,
      areaId: LifeAreaId(areaId),
    ),
  );

  Future<bool> makeDefault(String areaId) => _run(
    'areaDefaultSet',
    () => _commands!.makeDefault(
      commandId: _id(),
      profileId: _profile!,
      areaId: LifeAreaId(areaId),
    ),
  );

  Future<bool> _run(
    String messageCode,
    Future<Result<CommittedCommandResult>> Function() run,
  ) async {
    if (!_wired) {
      state = const AreaFeedbackError(_unavailableFailure);
      return false;
    }
    final Result<CommittedCommandResult> result = await run();
    switch (result) {
      case Success<CommittedCommandResult>():
        ref.invalidate(lifeAreaListProvider);
        state = AreaFeedbackMessage(messageCode);
        return true;
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        state = AreaFeedbackError(failure);
        return false;
    }
  }
}

final NotifierProvider<AreaActionsController, AreaFeedback>
areaActionsProvider = NotifierProvider<AreaActionsController, AreaFeedback>(
  AreaActionsController.new,
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
