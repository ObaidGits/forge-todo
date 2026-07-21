import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/focus/application/focus_command_service.dart';
import 'package:forge/features/focus/application/focus_today_contract.dart';
import 'package:forge/features/habits/application/habit_command_service.dart';
import 'package:forge/features/habits/application/habit_query_service.dart';
import 'package:forge/features/home/application/home_layout_store.dart';
import 'package:forge/features/home/presentation/home_providers.dart';
import 'package:forge/features/learning/application/learning_resume_contract.dart';
import 'package:forge/features/tasks/application/task_command_service.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';

/// A generation-scoped [ProviderScope] that wires the Today screen's
/// composition seams to the constructed feature services at the runtime
/// composition root (R-HOME-001..005, design.md §6).
///
/// Home declares its cross-feature dependencies as null-defaulting seam
/// providers so the app stays safe and honest before the encrypted runtime is
/// open (an unwired slot simply collapses). This scope is the single place that
/// binds those seams to real, feature-owned *application* contracts once the
/// generation is available — never a feature's infrastructure or presentation
/// providers (design.md §4/§16). It follows the same composition-root pattern
/// as [ForgeCompositionRoot].
///
/// Every cross-feature service is optional: a slot whose service is not (yet)
/// provided keeps its safe null default and its Today section collapses
/// (R-HOME-002). This lets the app come up with just tasks wired and gain
/// habits, study, and focus as those stacks are constructed.
final class HomeFeatureScope extends StatelessWidget {
  const HomeFeatureScope({
    required this.profileId,
    required this.quickCaptureArea,
    required this.clock,
    required this.layoutStore,
    required this.taskQuery,
    required this.taskCommands,
    required this.child,
    this.lifeAreaFilter,
    this.learningResume,
    this.habitQuery,
    this.habitCommands,
    this.focusContract,
    this.focusCommands,
    super.key,
  });

  final ProfileId profileId;
  final LifeAreaId quickCaptureArea;
  final Clock clock;
  final HomeLayoutStore layoutStore;
  final TaskQueryService taskQuery;
  final TaskCommandService taskCommands;
  final LifeAreaId? lifeAreaFilter;
  final LearningResumeContract? learningResume;
  final HabitQueryService? habitQuery;
  final HabitCommandService? habitCommands;
  final FocusTodayContract? focusContract;
  final FocusCommandService? focusCommands;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        activeProfileProvider.overrideWithValue(profileId),
        quickCaptureAreaProvider.overrideWithValue(quickCaptureArea),
        homeLifeAreaFilterProvider.overrideWithValue(lifeAreaFilter),
        homeClockProvider.overrideWithValue(clock),
        homeLayoutStoreProvider.overrideWithValue(layoutStore),
        taskQueryServiceProvider.overrideWithValue(taskQuery),
        taskCommandServiceProvider.overrideWithValue(taskCommands),
        // Progressive slots (R-HOME-002): an unwired service stays null so its
        // section collapses; a wired one lights the section up.
        learningResumeContractProvider.overrideWithValue(learningResume),
        homeHabitQueryServiceProvider.overrideWithValue(habitQuery),
        homeHabitCommandServiceProvider.overrideWithValue(habitCommands),
        homeFocusContractProvider.overrideWithValue(focusContract),
        homeFocusCommandServiceProvider.overrideWithValue(focusCommands),
      ],
      child: child,
    );
  }
}
