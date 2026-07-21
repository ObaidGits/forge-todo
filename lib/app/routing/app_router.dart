import 'package:flutter/material.dart';
import 'package:forge/app/navigation/forge_destination.dart';
import 'package:forge/app/navigation/forge_scaffold.dart';
import 'package:forge/app/routing/uri_policy.dart';
import 'package:forge/core/ui/forge_error.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/areas/presentation/life_area_management_screen.dart';
import 'package:forge/features/backup/presentation/recovery_center_page.dart';
import 'package:forge/features/fitness/presentation/fitness_screen.dart';
import 'package:forge/features/fitness/presentation/fitness_workout_screen.dart';
import 'package:forge/features/focus/presentation/focus_screen.dart';
import 'package:forge/features/focus/presentation/focus_session_screen.dart';
import 'package:forge/features/goals/presentation/goal_detail_screen.dart';
import 'package:forge/features/goals/presentation/goal_list_screen.dart';
import 'package:forge/features/goals/presentation/roadmap_outline_screen.dart';
import 'package:forge/features/habits/presentation/habit_detail_screen.dart';
import 'package:forge/features/habits/presentation/habit_list_screen.dart';
import 'package:forge/features/home/presentation/today_screen.dart';
import 'package:forge/features/insights/presentation/insights_screen.dart';
import 'package:forge/features/learning/presentation/learning_item_screen.dart';
import 'package:forge/features/learning/presentation/learning_list_screen.dart';
import 'package:forge/features/learning/presentation/learning_resource_screen.dart';
import 'package:forge/features/notes/presentation/note_editor_screen.dart';
import 'package:forge/features/notes/presentation/note_list_screen.dart';
import 'package:forge/features/planner/presentation/planner_screen.dart';
import 'package:forge/features/planner/presentation/planning_period_screen.dart';
import 'package:forge/features/search/presentation/search_screen.dart';
import 'package:forge/features/settings/presentation/settings_screen.dart';
import 'package:forge/features/sync/presentation/account_sync_screen.dart';
import 'package:forge/features/tasks/application/task_views.dart';
import 'package:forge/features/tasks/presentation/saved_filter_task_list_screen.dart';
import 'package:forge/features/tasks/presentation/task_detail_screen.dart';
import 'package:forge/features/tasks/presentation/task_list_screen.dart';
import 'package:go_router/go_router.dart';

GoRouter createForgeRouter({
  String initialLocation = '/today',
  UriPolicy? uriPolicy,
  VoidCallback? onQuickCapture,
  VoidCallback? onRequestQuit,
  bool? showMenuBar,
}) {
  final UriPolicy policy = uriPolicy ?? UriPolicy();
  return GoRouter(
    initialLocation: initialLocation,
    restorationScopeId: 'forgeRouter',
    routes: <RouteBase>[
      ShellRoute(
        restorationScopeId: 'forgeShell',
        builder: (BuildContext context, GoRouterState state, Widget child) =>
            ForgeScaffold(
              onQuickCapture: onQuickCapture,
              onRequestQuit: onRequestQuit,
              showMenuBar: showMenuBar,
              child: child,
            ),
        routes: <RouteBase>[
          _route(
            '/today',
            'today',
            ForgeDestination.today,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const TodayScreen(),
          ),
          _route(
            '/tasks',
            'tasks',
            ForgeDestination.tasks,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const TaskListScreen(initialView: TaskListView.today),
          ),
          _route(
            '/tasks/today',
            'tasksToday',
            ForgeDestination.tasks,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const TaskListScreen(initialView: TaskListView.today),
          ),
          _route(
            '/tasks/upcoming',
            'tasksUpcoming',
            ForgeDestination.tasks,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const TaskListScreen(initialView: TaskListView.upcoming),
          ),
          _route(
            '/tasks/completed',
            'tasksCompleted',
            ForgeDestination.tasks,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const TaskListScreen(initialView: TaskListView.completed),
          ),
          _route(
            '/tasks/filter/:filterId',
            'taskFilter',
            ForgeDestination.tasks,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                SavedFilterTaskListScreen(
                  filterId: state.pathParameters['filterId'] ?? '',
                ),
          ),
          _route(
            '/tasks/:taskId',
            'taskDetail',
            ForgeDestination.tasks,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                TaskDetailScreen(taskId: state.pathParameters['taskId'] ?? ''),
          ),
          _route(
            '/goals',
            'goals',
            ForgeDestination.goals,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const GoalListScreen(),
          ),
          _route(
            '/goals/:goalId',
            'goalDetail',
            ForgeDestination.goals,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                GoalDetailScreen(goalId: state.pathParameters['goalId'] ?? ''),
          ),
          _route(
            '/goals/:goalId/roadmap',
            'roadmap',
            ForgeDestination.goals,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                RoadmapOutlineScreen(
                  goalId: state.pathParameters['goalId'] ?? '',
                ),
          ),
          _route(
            '/learn',
            'learn',
            ForgeDestination.learn,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const LearningListScreen(),
          ),
          _route(
            '/learn/:resourceId',
            'learningResource',
            ForgeDestination.learn,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                LearningResourceScreen(
                  resourceId: state.pathParameters['resourceId'] ?? '',
                ),
          ),
          _route(
            '/learn/:resourceId/item/:itemId',
            'learningItem',
            ForgeDestination.learn,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                LearningItemScreen(
                  resourceId: state.pathParameters['resourceId'] ?? '',
                  itemId: state.pathParameters['itemId'] ?? '',
                ),
          ),
          _route(
            '/habits',
            'habits',
            ForgeDestination.habits,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const HabitListScreen(),
          ),
          _route(
            '/habits/:habitId',
            'habitDetail',
            ForgeDestination.habits,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                HabitDetailScreen(
                  habitId: state.pathParameters['habitId'] ?? '',
                ),
          ),
          _route(
            '/notes',
            'notes',
            ForgeDestination.notes,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const NoteListScreen(),
          ),
          _route(
            '/notes/:noteId',
            'noteDetail',
            ForgeDestination.notes,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                NoteEditorScreen(noteId: state.pathParameters['noteId'] ?? ''),
          ),
          _route(
            '/planner',
            'planner',
            ForgeDestination.planner,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const PlannerScreen(),
          ),
          // A planningPeriodId is the opaque record id (a UUID), so this route
          // loads that exact area-scoped record via PlannerRepository.findById
          // and renders an editor bound to it, showing only the named sections
          // applicable to its kind (day vs week/month) (R-PLAN-001, R-PLAN-004).
          _route(
            '/planner/:planningPeriodId',
            'planningPeriod',
            ForgeDestination.planner,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                PlanningPeriodScreen(
                  periodId: state.pathParameters['planningPeriodId'] ?? '',
                ),
          ),
          _route(
            '/focus',
            'focus',
            ForgeDestination.focus,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const FocusScreen(),
          ),
          _route(
            '/focus/:sessionId',
            'focusSession',
            ForgeDestination.focus,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                FocusSessionScreen(
                  sessionId: state.pathParameters['sessionId'] ?? '',
                ),
          ),
          _route(
            '/fitness',
            'fitness',
            ForgeDestination.settings,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const FitnessScreen(),
          ),
          // A workout id is the canonical logged-session id (see
          // WorkoutSearchProjector / CanonicalEntityType.workout), so this
          // route renders that session's read-only detail: its exercises and
          // sets shown exactly as recorded, non-medical (R-FIT-004, R-FIT-005).
          _route(
            '/fitness/:workoutId',
            'workout',
            ForgeDestination.settings,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                FitnessWorkoutScreen(
                  workoutId: state.pathParameters['workoutId'] ?? '',
                ),
          ),
          // Insights has no navigation-rail tab; it is reached from the
          // Settings hub like Fitness, so it highlights the Settings
          // destination (R-INSIGHT-001; ux-design nav map).
          _route(
            '/insights',
            'insights',
            ForgeDestination.settings,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const InsightsScreen(),
          ),
          // The Recovery Center has no navigation-rail tab; it is reached from
          // the Settings hub like Fitness/Insights, so it highlights the
          // Settings destination (R-BACKUP-003, R-BACKUP-004; ux-design nav
          // map). Restore is always the existing non-destructive staged
          // generation restore.
          _route(
            '/recovery',
            'recovery',
            ForgeDestination.settings,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const RecoveryCenterPage(),
          ),
          // Optional cloud sync (R-SYNC-001/005/007). Reached from the Settings
          // hub only when a backend is configured; otherwise the screen shows
          // an honest "not configured" state. Highlights the Settings dest.
          _route(
            '/account-sync',
            'accountSync',
            ForgeDestination.settings,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const AccountSyncScreen(),
          ),
          _route(
            '/search',
            'search',
            ForgeDestination.today,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const SearchScreen(),
          ),
          _route(
            '/settings',
            'settings',
            ForgeDestination.settings,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                const SettingsScreen(),
          ),
          _route(
            '/settings/:section',
            'settingsSection',
            ForgeDestination.settings,
            policy,
            content: (BuildContext context, GoRouterState state) =>
                state.pathParameters['section'] == 'areas'
                ? const LifeAreaManagementScreen()
                : const SettingsScreen(),
          ),
        ],
      ),
    ],
    errorBuilder: (BuildContext context, GoRouterState state) => Scaffold(
      body: ForgeErrorView(
        title: context.l10n.invalidLinkTitle,
        message: context.l10n.invalidLinkMessage,
        onReturnToday: () => context.go('/today'),
      ),
    ),
  );
}

GoRoute _route(
  String path,
  String name,
  ForgeDestination destination,
  UriPolicy policy, {
  Widget Function(BuildContext context, GoRouterState state)? content,
}) {
  return GoRoute(
    path: path,
    name: name,
    pageBuilder: (BuildContext context, GoRouterState state) {
      final UriRejection? rejection = policy.validateRouteLocation(
        state.uri.path,
      );
      final Widget child = rejection == null
          ? (content?.call(context, state) ??
                _RoutePlaceholder(destination: destination))
          : ForgeErrorView(
              title: context.l10n.invalidLinkTitle,
              message: context.l10n.invalidLinkMessage,
              onReturnToday: () => context.go('/today'),
            );
      return MaterialPage<void>(
        key: state.pageKey,
        restorationId: rejection == null
            ? 'route-${destination.name}'
            : 'invalidLink',
        child: child,
      );
    },
  );
}

final class _RoutePlaceholder extends StatelessWidget {
  const _RoutePlaceholder({required this.destination});

  final ForgeDestination destination;

  @override
  Widget build(BuildContext context) {
    final String section = destination.label(context.l10n);
    return ListView(
      restorationId: 'content-${destination.name}',
      padding: const EdgeInsets.all(ForgeSpacing.lg),
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: ForgeSizes.readableContentMaxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Semantics(
                header: true,
                child: Text(
                  section,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              const SizedBox(height: ForgeSpacing.md),
              Text(context.l10n.tagline),
              const SizedBox(height: ForgeSpacing.sm),
              Text(context.l10n.routePlaceholder),
              ExcludeSemantics(
                child: Text(context.l10n.currentRouteLabel(section)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
