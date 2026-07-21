import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/habits/application/habit_query_service.dart';
import 'package:forge/features/habits/presentation/habit_labels.dart';
import 'package:forge/features/habits/presentation/habit_providers.dart';
import 'package:forge/features/habits/presentation/widgets/habit_calendar_view.dart';
import 'package:forge/features/habits/presentation/widgets/habit_feedback_listener.dart';
import 'package:forge/features/habits/presentation/widgets/habit_impact_preview_sheet.dart';
import 'package:forge/features/habits/presentation/widgets/habit_statistics_card.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

/// The habit detail surface: history, calendar, and statistics (R-HABIT-004,
/// R-HABIT-005, R-HABIT-007).
///
/// Three tabs present the habit's occurrence history, a month calendar, and its
/// transparent streak/consistency statistics. History and calendar both open
/// the backfill impact-preview interface for a date so a correction's metric
/// effect can be previewed before it is committed (R-HABIT-005). All copy is
/// neutral and non-shaming (R-HABIT-006).
final class HabitDetailScreen extends ConsumerWidget {
  const HabitDetailScreen({required this.habitId, super.key});

  final String habitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<HabitSummary?> summary = ref.watch(
      habitSummaryProvider(habitId),
    );

    ref.listen<HabitFeedback>(habitActionsProvider, (_, HabitFeedback next) {
      handleHabitFeedback(
        context,
        ref,
        next,
        dismiss: () => ref.read(habitActionsProvider.notifier).dismiss(),
      );
    });

    return summary.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, _) => Center(child: Text(l10n.errorUnexpected)),
      data: (HabitSummary? view) {
        if (view == null) {
          return _NotFound(message: l10n.habitDetailNotFound);
        }
        return _DetailBody(summary: view);
      },
    );
  }
}

final class _DetailBody extends ConsumerWidget {
  const _DetailBody({required this.summary});

  final HabitSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final DateTime now = ref.watch(habitsClockProvider).utcNow();

    return DefaultTabController(
      length: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ForgeSpacing.md,
              ForgeSpacing.md,
              ForgeSpacing.md,
              ForgeSpacing.xs,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      summary.title,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                ),
                if (summary.isPaused)
                  Chip(
                    label: Text(l10n.habitStatusPaused),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
          TabBar(
            tabs: <Widget>[
              Tab(text: l10n.habitDetailTabHistory),
              Tab(text: l10n.habitDetailTabCalendar),
              Tab(text: l10n.habitDetailTabStatistics),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: <Widget>[
                _HistoryTab(summary: summary),
                _CalendarTab(
                  summary: summary,
                  year: now.year,
                  month: now.month,
                ),
                _StatisticsTab(habitId: summary.habitId),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _HistoryTab extends ConsumerWidget {
  const _HistoryTab({required this.summary});

  final HabitSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<HabitOccurrenceView>> history = ref.watch(
      habitHistoryProvider(summary.habitId),
    );
    return history.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, _) => Center(child: Text(l10n.errorUnexpected)),
      data: (List<HabitOccurrenceView> list) {
        if (list.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(ForgeSpacing.xl),
              child: Text(l10n.habitHistoryEmpty),
            ),
          );
        }
        return Semantics(
          label: l10n.habitHistoryLabel,
          child: ListView.separated(
            restorationId: 'content-habit-history',
            padding: const EdgeInsets.all(ForgeSpacing.sm),
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) {
              final HabitOccurrenceView occurrence = list[index];
              return ListTile(
                key: ValueKey<String>('habit-history-${occurrence.anchorIso}'),
                title: Text(occurrence.anchorIso),
                subtitle: Text(
                  HabitLabels.occurrenceStatus(
                    l10n,
                    occurrence.statusWire,
                    isPaused: occurrence.isPaused,
                  ),
                ),
                trailing: const Icon(Icons.tune),
                onTap: () => showHabitImpactPreview(
                  context,
                  habitId: summary.habitId,
                  targetKindWire: summary.targetKindWire,
                  dateIso: occurrence.anchorIso,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

final class _CalendarTab extends StatelessWidget {
  const _CalendarTab({
    required this.summary,
    required this.year,
    required this.month,
  });

  final HabitSummary summary;
  final int year;
  final int month;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      restorationId: 'content-habit-calendar',
      padding: const EdgeInsets.all(ForgeSpacing.md),
      child: HabitCalendarView(
        habitId: summary.habitId,
        targetKindWire: summary.targetKindWire,
        initialYear: year,
        initialMonth: month,
        onDayTap: (String dayIso) => showHabitImpactPreview(
          context,
          habitId: summary.habitId,
          targetKindWire: summary.targetKindWire,
          dateIso: dayIso,
        ),
      ),
    );
  }
}

final class _StatisticsTab extends ConsumerWidget {
  const _StatisticsTab({required this.habitId});

  final String habitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<HabitStatistics?> stats = ref.watch(
      habitStatisticsProvider(habitId),
    );
    return stats.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, _) => Center(child: Text(l10n.errorUnexpected)),
      data: (HabitStatistics? value) {
        if (value == null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(ForgeSpacing.xl),
              child: Text(l10n.habitsUnavailable),
            ),
          );
        }
        return ListView(
          restorationId: 'content-habit-statistics',
          padding: const EdgeInsets.all(ForgeSpacing.md),
          children: <Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: ForgeSizes.readableContentMaxWidth,
              ),
              child: HabitStatisticsCard(statistics: value),
            ),
          ],
        );
      },
    );
  }
}

final class _NotFound extends StatelessWidget {
  const _NotFound({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ForgeSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: ForgeSpacing.md),
            FilledButton(
              onPressed: () => context.go('/habits'),
              child: Text(context.l10n.navHabits),
            ),
          ],
        ),
      ),
    );
  }
}
