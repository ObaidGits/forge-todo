import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/habits/application/habit_query_service.dart';
import 'package:forge/features/habits/presentation/habit_providers.dart';
import 'package:forge/features/habits/presentation/widgets/habit_check_row.dart';
import 'package:forge/features/habits/presentation/widgets/habit_feedback_listener.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// The Today habit checklist (R-HOME-001, R-HOME-003, R-HABIT-006).
///
/// One accessible, adaptive list of the habit occurrences scheduled for today,
/// each with an inline check-in control so a habit can be logged without leaving
/// the screen (R-HOME-003). Content is reconstructed from the local generation,
/// so it is available offline (R-GEN-001). Copy is neutral throughout: an unlogged
/// occurrence is stated factually and never framed as a personal failure
/// (R-HABIT-006).
final class HabitListScreen extends ConsumerWidget {
  const HabitListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<HabitTodayEntry>> entries = ref.watch(
      habitTodayProvider,
    );

    ref.listen<HabitFeedback>(habitActionsProvider, (_, HabitFeedback next) {
      handleHabitFeedback(
        context,
        ref,
        next,
        dismiss: () => ref.read(habitActionsProvider.notifier).dismiss(),
      );
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ForgeSpacing.md,
            ForgeSpacing.md,
            ForgeSpacing.md,
            ForgeSpacing.xs,
          ),
          child: Semantics(
            header: true,
            child: Text(
              l10n.navHabits,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: entries.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object error, _) =>
                Center(child: Text(l10n.errorUnexpected)),
            data: (List<HabitTodayEntry> list) =>
                _buildList(context, ref, list),
          ),
        ),
      ],
    );
  }

  Widget _buildList(
    BuildContext context,
    WidgetRef ref,
    List<HabitTodayEntry> list,
  ) {
    final AppLocalizations l10n = context.l10n;
    if (!ref.read(habitsConfiguredProvider)) {
      return _EmptyView(message: l10n.habitsUnavailable);
    }
    if (list.isEmpty) {
      return _EmptyView(message: l10n.habitsTodayEmpty);
    }
    return FocusTraversalGroup(
      child: Semantics(
        label: l10n.habitsListLabel,
        child: ListView.separated(
          restorationId: 'content-habits-today',
          padding: const EdgeInsets.all(ForgeSpacing.xs),
          itemCount: list.length,
          separatorBuilder: (_, _) => const SizedBox(height: ForgeSpacing.xxs),
          itemBuilder: (BuildContext context, int index) {
            return ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: ForgeSizes.readableContentMaxWidth,
              ),
              child: HabitCheckRow(entry: list[index]),
            );
          },
        ),
      ),
    );
  }
}

final class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ForgeSpacing.xl),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    );
  }
}
