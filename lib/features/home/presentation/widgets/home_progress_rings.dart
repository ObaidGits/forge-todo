import 'package:flutter/material.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/home/application/home_content.dart';

/// Compact progress rings for Today (R-HOME-001, ux-design §8).
///
/// Each ring exposes its value in text and a semantic label so it never relies
/// on color or shape alone (R-INSIGHT-003, NFR-A11Y-002). A ring with no data
/// shows "No data yet" rather than a misleading 0%.
final class HomeProgressRings extends StatelessWidget {
  const HomeProgressRings({required this.rings, super.key});

  final List<HomeProgressRing> rings;

  @override
  Widget build(BuildContext context) {
    // ux-design §8: at most 2–4 rings on Today.
    final List<HomeProgressRing> shown = rings.take(4).toList(growable: false);
    return Wrap(
      spacing: ForgeSpacing.lg,
      runSpacing: ForgeSpacing.md,
      children: <Widget>[
        for (final HomeProgressRing ring in shown) _ProgressRing(ring: ring),
      ],
    );
  }
}

final class _ProgressRing extends StatelessWidget {
  const _ProgressRing({required this.ring});

  final HomeProgressRing ring;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String valueText = ring.hasData
        ? '${ring.completed}/${ring.total}'
        : '—';
    final bool isHabits = ring.id == 'habits_today';
    final String semanticLabel = ring.hasData
        ? (isHabits
              ? context.l10n.progressHabitsLabel(ring.completed, ring.total)
              : context.l10n.progressTasksLabel(ring.completed, ring.total))
        : context.l10n.progressNoData;
    final String caption = isHabits
        ? context.l10n.homeSectionHabits
        : context.l10n.homeSectionProgress;

    return Semantics(
      label: semanticLabel,
      value: valueText,
      child: ExcludeSemantics(
        child: SizedBox(
          width: 96,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 56,
                height: 56,
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    CircularProgressIndicator(
                      value: ring.hasData ? ring.fraction : 0,
                      strokeWidth: 6,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                    ),
                    Text(valueText, style: theme.textTheme.labelMedium),
                  ],
                ),
              ),
              const SizedBox(height: ForgeSpacing.xs),
              Text(
                ring.hasData ? caption : context.l10n.progressNoData,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
