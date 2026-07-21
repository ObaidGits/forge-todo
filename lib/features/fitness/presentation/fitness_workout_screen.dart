import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/forge_empty_state.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/fitness/domain/workout_session.dart';
import 'package:forge/features/fitness/presentation/fitness_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// A read-only detail surface for one logged workout session (R-FIT-001,
/// R-FIT-004, R-FIT-005).
///
/// It renders the underlying records behind a `/fitness/<id>` deep link: the
/// session's title and logged date, then each performed exercise with its
/// rank-ordered sets, showing the exact entered reps/weight/distance/duration
/// with no medical interpretation layered on top. Content is reconstructed from
/// the local generation, so it is available offline (R-GEN-001).
final class FitnessWorkoutScreen extends ConsumerWidget {
  const FitnessWorkoutScreen({required this.workoutId, super.key});

  final String workoutId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<FitnessWorkoutDetail?> detail = ref.watch(
      fitnessWorkoutDetailProvider(workoutId),
    );

    return detail.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace _) =>
          Center(child: Text(l10n.errorUnexpected)),
      data: (FitnessWorkoutDetail? data) {
        if (data == null) {
          return ForgeEmptyState(
            icon: Icons.fitness_center_outlined,
            title: l10n.fitnessWorkoutTitle,
            body: l10n.fitnessWorkoutNotFound,
          );
        }
        return _Detail(detail: data);
      },
    );
  }
}

final class _Detail extends StatelessWidget {
  const _Detail({required this.detail});

  final FitnessWorkoutDetail detail;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);

    return FocusTraversalGroup(
      child: ListView(
        restorationId: 'content-fitness-workout-${detail.session.id.value}',
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
                    detail.session.title,
                    style: theme.textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: ForgeSpacing.xxs),
                Text(
                  l10n.fitnessLoggedOn(
                    _formatDate(detail.session.startedAtUtc),
                  ),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: ForgeSpacing.lg),
                Semantics(
                  header: true,
                  child: Text(
                    l10n.fitnessWorkoutExercises,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: ForgeSpacing.xs),
                if (detail.exercises.isEmpty)
                  Text(
                    l10n.fitnessWorkoutNoExercises,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  for (final ExerciseWithSets exercise in detail.exercises)
                    _ExerciseCard(
                      key: ValueKey<String>(
                        'workout-exercise-${exercise.exercise.id.value}',
                      ),
                      exercise: exercise,
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _ExerciseCard extends StatelessWidget {
  const _ExerciseCard({required this.exercise, super.key});

  final ExerciseWithSets exercise;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: ForgeSpacing.xxs),
      child: Padding(
        padding: const EdgeInsets.all(ForgeSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Semantics(
              header: true,
              child: Text(
                exercise.exercise.name,
                style: theme.textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: ForgeSpacing.xs),
            if (exercise.sets.isEmpty)
              Text(
                l10n.fitnessWorkoutNoSets,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (int i = 0; i < exercise.sets.length; i++)
                _SetRow(number: i + 1, set: exercise.sets[i]),
          ],
        ),
      ),
    );
  }
}

final class _SetRow extends StatelessWidget {
  const _SetRow({required this.number, required this.set});

  final int number;
  final SetLog set;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final String? detail = _setDetail(l10n, set);
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: ForgeSizes.minimumInteractiveDimension,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: ForgeSpacing.xxs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 64,
              child: Text(
                l10n.fitnessSetNumber(number),
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: ForgeSpacing.xs),
            Expanded(
              child: Text(
                detail ?? '—',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: detail == null
                      ? theme.colorScheme.onSurfaceVariant
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Builds a plain, non-medical description of a set from the exact recorded
/// values (R-FIT-002, R-FIT-004). Returns null when the set has no measures.
String? _setDetail(AppLocalizations l10n, SetLog set) {
  final List<String> parts = <String>[];
  final int? reps = set.reps;
  if (reps != null) {
    parts.add(l10n.fitnessReps(reps));
  }
  final weight = set.weight;
  if (weight != null) {
    parts.add('${_formatValue(weight.enteredValue)} ${weight.enteredUnit}');
  }
  final distance = set.distance;
  if (distance != null) {
    parts.add('${_formatValue(distance.enteredValue)} ${distance.enteredUnit}');
  }
  final int? durationSec = set.durationSec;
  if (durationSec != null) {
    parts.add(l10n.fitnessSetDurationSec(durationSec));
  }
  return parts.isEmpty ? null : parts.join(' · ');
}

String _formatValue(num value) {
  if (value is int || value == value.roundToDouble()) {
    return value.toInt().toString();
  }
  return value.toString();
}

String _formatDate(int utcMicros) {
  final DateTime dt = DateTime.fromMicrosecondsSinceEpoch(
    utcMicros,
    isUtc: true,
  );
  final String month = dt.month.toString().padLeft(2, '0');
  final String day = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$month-$day';
}
