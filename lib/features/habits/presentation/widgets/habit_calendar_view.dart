import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/habits/application/habit_query_service.dart';
import 'package:forge/features/habits/presentation/habit_labels.dart';
import 'package:forge/features/habits/presentation/habit_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// The habit calendar view (ux-design §8): a month grid of occurrence statuses.
///
/// Each day that has a materialized occurrence shows its neutral status label,
/// never color alone (ux-design §5); tapping a day opens the backfill
/// impact-preview interface for that date (R-HABIT-005). Month navigation is an
/// explicit, keyboard-reachable control (NFR-A11Y-001).
final class HabitCalendarView extends ConsumerStatefulWidget {
  const HabitCalendarView({
    required this.habitId,
    required this.targetKindWire,
    required this.initialYear,
    required this.initialMonth,
    required this.onDayTap,
    super.key,
  });

  final String habitId;
  final String targetKindWire;
  final int initialYear;
  final int initialMonth;

  /// Called with the tapped day's ISO date so the parent can open the impact
  /// preview.
  final void Function(String dayIso) onDayTap;

  @override
  ConsumerState<HabitCalendarView> createState() => _HabitCalendarViewState();
}

class _HabitCalendarViewState extends ConsumerState<HabitCalendarView> {
  late int _year = widget.initialYear;
  late int _month = widget.initialMonth;

  void _shiftMonth(int delta) {
    final LocalDate shifted = LocalDate(_year, _month, 1).addMonths(delta);
    setState(() {
      _year = shifted.year;
      _month = shifted.month;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<HabitCalendarMonth?> month = ref.watch(
      habitCalendarProvider((
        habitId: widget.habitId,
        year: _year,
        month: _month,
      )),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _MonthHeader(
          year: _year,
          month: _month,
          onPrevious: () => _shiftMonth(-1),
          onNext: () => _shiftMonth(1),
        ),
        const SizedBox(height: ForgeSpacing.sm),
        month.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (Object error, _) => Text(l10n.errorUnexpected),
          data: (HabitCalendarMonth? data) => _grid(context, data),
        ),
      ],
    );
  }

  Widget _grid(BuildContext context, HabitCalendarMonth? data) {
    final AppLocalizations l10n = context.l10n;
    final int days = LocalDate(_year, _month, 1).daysInMonth;
    final Map<String, HabitOccurrenceView> byDay =
        data?.occurrencesByDayIso ?? const <String, HabitOccurrenceView>{};

    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: ForgeSpacing.xxs,
      crossAxisSpacing: ForgeSpacing.xxs,
      children: <Widget>[
        for (int day = 1; day <= days; day += 1)
          _DayCell(
            key: ValueKey<String>('habit-calendar-day-$day'),
            day: day,
            dayIso: LocalDate(_year, _month, day).iso,
            occurrence: byDay[LocalDate(_year, _month, day).iso],
            label: _dayLabel(l10n, day, byDay),
            onTap: () => widget.onDayTap(LocalDate(_year, _month, day).iso),
          ),
      ],
    );
  }

  String _dayLabel(
    AppLocalizations l10n,
    int day,
    Map<String, HabitOccurrenceView> byDay,
  ) {
    final String iso = LocalDate(_year, _month, day).iso;
    final HabitOccurrenceView? occurrence = byDay[iso];
    final String status = occurrence == null
        ? l10n.habitStatusOpen
        : HabitLabels.occurrenceStatus(
            l10n,
            occurrence.statusWire,
            isPaused: occurrence.isPaused,
          );
    return l10n.habitCalendarDayStatus(iso, status);
  }
}

final class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.year,
    required this.month,
    required this.onPrevious,
    required this.onNext,
  });

  final int year;
  final int month;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final String title = l10n.habitCalendarMonthTitle(
      year.toString().padLeft(4, '0'),
      month.toString().padLeft(2, '0'),
    );
    return Row(
      children: <Widget>[
        IconButton(
          icon: const Icon(Icons.chevron_left),
          tooltip: l10n.habitCalendarPrevMonth,
          onPressed: onPrevious,
        ),
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          tooltip: l10n.habitCalendarNextMonth,
          onPressed: onNext,
        ),
      ],
    );
  }
}

final class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.dayIso,
    required this.occurrence,
    required this.label,
    required this.onTap,
    super.key,
  });

  final int day;
  final String dayIso;
  final HabitOccurrenceView? occurrence;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color background = _backgroundColor(theme);
    return Semantics(
      button: true,
      label: label,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(ForgeRadii.control),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(ForgeRadii.control),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text('$day', style: theme.textTheme.bodyMedium),
                if (occurrence != null)
                  Text(
                    _shortStatus(occurrence!),
                    style: theme.textTheme.labelSmall,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _backgroundColor(ThemeData theme) {
    if (occurrence == null) {
      return theme.colorScheme.surface;
    }
    if (occurrence!.isPaused) {
      return theme.colorScheme.surfaceContainerHighest;
    }
    return switch (occurrence!.statusWire) {
      'completed' => theme.colorScheme.primaryContainer,
      'missed' => theme.colorScheme.surfaceContainerHighest,
      'skipped' => theme.colorScheme.secondaryContainer,
      _ => theme.colorScheme.surface,
    };
  }

  /// A tiny text marker so status never relies on color alone (ux-design §5).
  String _shortStatus(HabitOccurrenceView o) {
    if (o.isPaused) {
      return '॥';
    }
    return switch (o.statusWire) {
      'completed' => '✓',
      'missed' => '–',
      'skipped' => '»',
      _ => '·',
    };
  }
}
