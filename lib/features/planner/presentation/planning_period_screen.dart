import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/forge_empty_state.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/planner/domain/planning_period.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';
import 'package:forge/features/planner/presentation/planner_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// The accessible editor for a single planning record addressed by its opaque
/// id (`/planner/<id>`) (R-PLAN-001, R-PLAN-004, NFR-A11Y-001/002/003).
///
/// Unlike the Planner tab — which always edits the current day's record for the
/// default Life Area — this surface loads the exact record the id addresses,
/// which may be a day, week, or month record for any area. It renders only the
/// named sections applicable to that record's kind (day: morning/daily/evening;
/// week & month: plan-intention/reflection) and saves create-or-update through
/// the same durable command service. Content is reconstructed from the local
/// generation, so it is available offline (R-GEN-001).
final class PlanningPeriodScreen extends ConsumerWidget {
  const PlanningPeriodScreen({required this.periodId, super.key});

  final String periodId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;

    ref.listen<PlannerFeedback>(plannerActionsProvider, (
      _,
      PlannerFeedback next,
    ) {
      final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
      if (next is PlannerFeedbackSaved) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(SnackBar(content: Text(l10n.plannerSaved)));
        ref.read(plannerActionsProvider.notifier).dismiss();
        ref.invalidate(plannerRecordProvider(periodId));
      } else if (next is PlannerFeedbackError) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(SnackBar(content: Text(l10n.errorUnexpected)));
        ref.read(plannerActionsProvider.notifier).dismiss();
      }
    });

    if (!ref.watch(plannerConfiguredProvider)) {
      return ForgeEmptyState(
        icon: Icons.calendar_month_outlined,
        title: l10n.navPlanner,
        body: l10n.plannerUnavailable,
      );
    }

    final AsyncValue<PlanningPeriod?> record = ref.watch(
      plannerRecordProvider(periodId),
    );
    return record.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace _) =>
          Center(child: Text(l10n.errorUnexpected)),
      data: (PlanningPeriod? period) {
        if (period == null) {
          return ForgeEmptyState(
            icon: Icons.calendar_month_outlined,
            title: l10n.navPlanner,
            body: l10n.plannerRecordNotFound,
          );
        }
        return _PlanningPeriodBody(
          key: ValueKey<String>('planning-period-${period.id.value}'),
          period: period,
        );
      },
    );
  }
}

final class _PlanningPeriodBody extends ConsumerStatefulWidget {
  const _PlanningPeriodBody({required this.period, super.key});

  final PlanningPeriod period;

  @override
  ConsumerState<_PlanningPeriodBody> createState() =>
      _PlanningPeriodBodyState();
}

class _PlanningPeriodBodyState extends ConsumerState<_PlanningPeriodBody> {
  // Day sections.
  late final TextEditingController _morning;
  late final TextEditingController _daily;
  late final TextEditingController _evening;
  // Aggregate (week/month) sections.
  late final TextEditingController _intention;
  late final TextEditingController _reflection;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final PlanningPeriod p = widget.period;
    _morning = TextEditingController(text: p.morningPlanMd ?? '');
    _daily = TextEditingController(text: p.dailyPlanMd ?? '');
    _evening = TextEditingController(text: p.eveningReflectionMd ?? '');
    _intention = TextEditingController(text: p.planIntentionMd ?? '');
    _reflection = TextEditingController(text: p.reflectionMd ?? '');
  }

  @override
  void dispose() {
    _morning.dispose();
    _daily.dispose();
    _evening.dispose();
    _intention.dispose();
    _reflection.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final PlanningPeriod p = widget.period;
    final PlannerActionsController actions = ref.read(
      plannerActionsProvider.notifier,
    );
    if (p.kind.hasDailySections) {
      await actions.saveRecord(
        lifeAreaId: p.lifeAreaId,
        kind: p.kind,
        periodKey: p.periodKey,
        morningPlanMd: _morning.text,
        dailyPlanMd: _daily.text,
        eveningReflectionMd: _evening.text,
      );
    } else {
      await actions.saveRecord(
        lifeAreaId: p.lifeAreaId,
        kind: p.kind,
        periodKey: p.periodKey,
        planIntentionMd: _intention.text,
        reflectionMd: _reflection.text,
      );
    }
    if (mounted) {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final PlanningPeriod p = widget.period;

    return FocusTraversalGroup(
      child: Semantics(
        label: _kindTitle(l10n, p.kind),
        child: ListView(
          restorationId: 'content-planning-period-${p.id.value}',
          padding: const EdgeInsets.all(ForgeSpacing.lg),
          children: <Widget>[
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: ForgeSizes.formMaxWidth,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Semantics(
                      header: true,
                      child: Text(
                        _kindTitle(l10n, p.kind),
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                    const SizedBox(height: ForgeSpacing.xxs),
                    Text(
                      l10n.plannerPeriodKeyLabel(p.periodKey),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: ForgeSpacing.lg),
                    if (p.kind.hasDailySections) ...<Widget>[
                      _SectionField(
                        controller: _morning,
                        label: l10n.plannerMorningLabel,
                        hint: l10n.plannerMorningHint,
                      ),
                      const SizedBox(height: ForgeSpacing.lg),
                      _SectionField(
                        controller: _daily,
                        label: l10n.plannerDailyLabel,
                        hint: l10n.plannerDailyHint,
                      ),
                      const SizedBox(height: ForgeSpacing.lg),
                      _SectionField(
                        controller: _evening,
                        label: l10n.plannerEveningLabel,
                        hint: l10n.plannerEveningHint,
                      ),
                    ] else ...<Widget>[
                      _SectionField(
                        controller: _intention,
                        label: l10n.plannerPlanIntentionLabel,
                        hint: l10n.plannerPlanIntentionHint,
                      ),
                      const SizedBox(height: ForgeSpacing.lg),
                      _SectionField(
                        controller: _reflection,
                        label: l10n.plannerReflectionLabel,
                        hint: l10n.plannerReflectionHint,
                      ),
                    ],
                    const SizedBox(height: ForgeSpacing.lg),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: ForgeSizes.minimumInteractiveDimension,
                        ),
                        child: FilledButton.icon(
                          onPressed: _saving ? null : () => unawaited(_save()),
                          icon: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_outlined),
                          label: Text(l10n.plannerSave),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _kindTitle(AppLocalizations l10n, PlanningPeriodKind kind) {
    return switch (kind) {
      PlanningPeriodKind.day => l10n.plannerPeriodDay,
      PlanningPeriodKind.week => l10n.plannerPeriodWeek,
      PlanningPeriodKind.month => l10n.plannerPeriodMonth,
    };
  }
}

/// One labelled, multiline free-text section (mirrors the Planner tab). The
/// label carries the meaning so the field is understandable without color
/// (NFR-A11Y-001/003).
final class _SectionField extends StatelessWidget {
  const _SectionField({
    required this.controller,
    required this.label,
    required this.hint,
  });

  final TextEditingController controller;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      minLines: 3,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        alignLabelWithHint: true,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
