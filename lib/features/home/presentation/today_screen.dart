import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/routing/canonical_route.dart';
import 'package:forge/core/ui/forge_empty_state.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/home/application/home_content.dart';
import 'package:forge/features/home/domain/home_layout.dart';
import 'package:forge/features/home/domain/home_section.dart';
import 'package:forge/features/home/presentation/home_providers.dart';
import 'package:forge/features/home/presentation/widgets/focus_slot_card.dart';
import 'package:forge/features/home/presentation/widgets/habit_action_row.dart';
import 'package:forge/features/home/presentation/widgets/home_progress_rings.dart';
import 'package:forge/features/home/presentation/widgets/home_section_card.dart';
import 'package:forge/features/home/presentation/widgets/quick_capture_field.dart';
import 'package:forge/features/home/presentation/widgets/task_action_row.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';
import 'package:go_router/go_router.dart';

/// The Today screen: one calm view of what matters now (R-HOME-001..005).
///
/// Cached local content renders immediately (R-HOME-005): quick capture is
/// always present and sections appear as soon as the local read resolves. Empty
/// and not-yet-shipped sections collapse (R-HOME-002); a fresh, sample-free
/// empty state invites the first capture (ux-design §7).
final class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<HomeState> home = ref.watch(homeControllerProvider);
    final HomeState? state = home.value;

    return ListView(
      restorationId: 'content-today',
      padding: const EdgeInsets.all(ForgeSpacing.lg),
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: ForgeSizes.readableContentMaxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _Header(layout: state?.layout),
              const SizedBox(height: ForgeSpacing.md),
              const QuickCaptureField(),
              const SizedBox(height: ForgeSpacing.lg),
              if (state == null)
                const _TodaySkeleton()
              else
                ..._buildSections(context, ref, state),
              if (state != null && state.configured)
                _SyncStatusLabel(status: state.content.syncStatus),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _buildSections(
    BuildContext context,
    WidgetRef ref,
    HomeState state,
  ) {
    final HomeLayout layout = state.layout;
    final HomeTodayContent content = state.content;
    final List<Widget> sections = <Widget>[];

    for (final HomeSectionKind kind in layout.visibleOrder) {
      final Widget? section = _sectionFor(context, ref, kind, layout, content);
      if (section != null) {
        sections.add(section);
      }
    }

    if (sections.isEmpty) {
      sections.add(const _EmptyToday());
    }
    return sections;
  }

  Widget? _sectionFor(
    BuildContext context,
    WidgetRef ref,
    HomeSectionKind kind,
    HomeLayout layout,
    HomeTodayContent content,
  ) {
    switch (kind) {
      case HomeSectionKind.overdue:
        return _taskSection(
          context,
          ref,
          kind,
          layout,
          context.l10n.homeSectionOverdue,
          content.agenda.overdue,
        );
      case HomeSectionKind.todayTasks:
        return _taskSection(
          context,
          ref,
          kind,
          layout,
          context.l10n.homeSectionToday,
          content.agenda.dueToday,
        );
      case HomeSectionKind.completed:
        return _taskSection(
          context,
          ref,
          kind,
          layout,
          context.l10n.homeSectionCompleted,
          content.agenda.completedToday,
        );
      case HomeSectionKind.progress:
        final bool hasData = content.progressRings.any(
          (HomeProgressRing r) => r.hasData,
        );
        if (!hasData) {
          return null; // collapse when there is no computable metric
        }
        return HomeSectionCard(
          kind: kind,
          title: context.l10n.homeSectionProgress,
          onMoveUp: () =>
              ref.read(homeControllerProvider.notifier).moveSectionUp(kind),
          onMoveDown: () =>
              ref.read(homeControllerProvider.notifier).moveSectionDown(kind),
          onHide: () =>
              ref.read(homeControllerProvider.notifier).hideSection(kind),
          child: HomeProgressRings(rings: content.progressRings),
        );
      case HomeSectionKind.resumeLearning:
        return _resumeLearningSection(context, ref, kind, content);
      case HomeSectionKind.habits:
        return _habitsSection(context, ref, kind, content);
      case HomeSectionKind.focus:
        return _focusSection(context, ref, kind, content);
      // Progressive slots — empty until their feature ships, so they collapse
      // (R-HOME-002). They are wired here as their features ship.
      case HomeSectionKind.quickNote:
        return null;
    }
  }

  /// Today's habit checklist (R-HOME-001, R-HOME-003). Each occurrence is an
  /// inline check-in row; the section collapses when nothing is scheduled today
  /// (R-HOME-002).
  Widget? _habitsSection(
    BuildContext context,
    WidgetRef ref,
    HomeSectionKind kind,
    HomeTodayContent content,
  ) {
    final List<HabitOccurrenceSlot> habits = content.habitOccurrences;
    if (habits.isEmpty) {
      return null;
    }
    final HomeController controller = ref.read(homeControllerProvider.notifier);
    return HomeSectionCard(
      kind: kind,
      title: context.l10n.homeSectionHabits,
      count: habits.length,
      onMoveUp: () => controller.moveSectionUp(kind),
      onMoveDown: () => controller.moveSectionDown(kind),
      onHide: () => controller.hideSection(kind),
      child: Column(
        children: <Widget>[
          for (final HabitOccurrenceSlot slot in habits)
            HabitActionRow(
              key: ValueKey<String>('home-habit-row-${slot.habitId}'),
              slot: slot,
            ),
        ],
      ),
    );
  }

  /// The active/next focus session (R-HOME-001, R-HOME-003). Unlike other slots
  /// this section is always shown when focus is wired: it either surfaces the
  /// open session or offers to start one. It collapses only when focus is not
  /// wired at all (no start affordance available).
  Widget? _focusSection(
    BuildContext context,
    WidgetRef ref,
    HomeSectionKind kind,
    HomeTodayContent content,
  ) {
    final bool focusWired = ref.watch(homeFocusCommandServiceProvider) != null;
    if (!focusWired && content.focus == null) {
      return null;
    }
    final HomeController controller = ref.read(homeControllerProvider.notifier);
    return HomeSectionCard(
      kind: kind,
      title: context.l10n.homeSectionFocus,
      onMoveUp: () => controller.moveSectionUp(kind),
      onMoveDown: () => controller.moveSectionDown(kind),
      onHide: () => controller.hideSection(kind),
      child: FocusSlotCard(focus: content.focus),
    );
  }

  /// The Today active-study recommendation (R-HOME-001, R-LEARN-003). It shows
  /// the resource to resume and its resume item, and opens the resource's
  /// canonical projection (`/learn/<id>`) without mutating it. The section
  /// collapses when there is nothing to resume (R-HOME-002).
  Widget? _resumeLearningSection(
    BuildContext context,
    WidgetRef ref,
    HomeSectionKind kind,
    HomeTodayContent content,
  ) {
    final StudyRecommendationSlot? study = content.studyRecommendation;
    if (study == null) {
      return null;
    }
    final HomeController controller = ref.read(homeControllerProvider.notifier);
    final String subtitle = study.resumeItemTitle != null
        ? context.l10n.homeResumeLearningItem(study.resumeItemTitle!)
        : context.l10n.homeResumeLearningResource;
    final String? route = CanonicalRoute.forEntity(
      CanonicalEntityType.learningResource,
      study.resourceId,
    );
    return HomeSectionCard(
      kind: kind,
      title: context.l10n.homeSectionResumeLearning,
      onMoveUp: () => controller.moveSectionUp(kind),
      onMoveDown: () => controller.moveSectionDown(kind),
      onHide: () => controller.hideSection(kind),
      child: Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          key: const ValueKey<String>('resume-learning-tile'),
          leading: const Icon(Icons.play_circle_outline),
          title: Text(study.title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: route == null ? null : () => context.push(route),
        ),
      ),
    );
  }

  Widget? _taskSection(
    BuildContext context,
    WidgetRef ref,
    HomeSectionKind kind,
    HomeLayout layout,
    String title,
    List<TaskSummary> tasks,
  ) {
    if (tasks.isEmpty) {
      return null; // collapse empty section
    }
    final HomeController controller = ref.read(homeControllerProvider.notifier);
    return HomeSectionCard(
      kind: kind,
      title: title,
      count: tasks.length,
      onMoveUp: () => controller.moveSectionUp(kind),
      onMoveDown: () => controller.moveSectionDown(kind),
      onHide: () => controller.hideSection(kind),
      child: Column(
        children: <Widget>[
          for (final TaskSummary task in tasks)
            TaskActionRow(
              key: ValueKey<String>('task-${task.id}'),
              task: task,
              onToggleComplete: (bool complete) => controller.setTaskComplete(
                taskId: task.id,
                complete: complete,
              ),
            ),
        ],
      ),
    );
  }
}

final class _Header extends ConsumerWidget {
  const _Header({this.layout});

  final HomeLayout? layout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool canReset = layout != null && !layout!.isDefault;
    return Row(
      children: <Widget>[
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              context.l10n.todayHeading,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: context.l10n.homeCustomize,
          icon: const Icon(Icons.tune),
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            PopupMenuItem<String>(
              value: 'reset',
              enabled: canReset,
              child: Text(context.l10n.homeResetLayout),
            ),
          ],
          onSelected: (String value) {
            if (value == 'reset') {
              unawaited(
                ref.read(homeControllerProvider.notifier).resetLayout(),
              );
            }
          },
        ),
      ],
    );
  }
}

final class _SyncStatusLabel extends StatelessWidget {
  const _SyncStatusLabel({required this.status});

  final HomeSyncStatus status;

  @override
  Widget build(BuildContext context) {
    final String text = switch (status) {
      HomeSyncStatus.localOnly => context.l10n.homeSyncLocalOnly,
      HomeSyncStatus.pendingSync => context.l10n.homeSyncPending,
      HomeSyncStatus.syncError => context.l10n.homeSyncError,
    };
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: ForgeSpacing.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.cloud_off,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: ForgeSpacing.xxs),
          Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

final class _EmptyToday extends StatelessWidget {
  const _EmptyToday();

  @override
  Widget build(BuildContext context) {
    return ForgeEmptyState(
      compact: true,
      title: context.l10n.homeEmptyTitle,
      body: context.l10n.homeEmptyBody,
    );
  }
}

final class _TodaySkeleton extends StatelessWidget {
  const _TodaySkeleton();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: context.l10n.todayHeading,
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: ForgeSpacing.xl),
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}
