import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/forge_empty_state.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/planner/presentation/planner_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// The accessible daily planning record for the current planning day
/// (R-PLAN-001, R-PLAN-004, NFR-A11Y-001/002/003).
///
/// The Planner tab renders the single area-scoped daily record for the default
/// Life Area with its three named sections — morning plan, daily plan, and
/// evening reflection — as labelled multiline text fields with an explicit
/// Save. Every section is free text and optional/skippable. Content is
/// reconstructed from the local generation, so it is available offline
/// (R-GEN-001). Saving creates-or-updates the one record through the durable
/// command service; it never alters task due dates or carry-forward relations.
final class PlannerScreen extends ConsumerWidget {
  const PlannerScreen({super.key});

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

    final AsyncValue<PlannerDailyView?> daily = ref.watch(plannerDailyProvider);
    return daily.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, _) => Center(child: Text(l10n.errorUnexpected)),
      data: (PlannerDailyView? view) {
        if (view == null) {
          return ForgeEmptyState(
            icon: Icons.calendar_month_outlined,
            title: l10n.navPlanner,
            body: l10n.plannerUnavailable,
          );
        }
        return _PlannerDailyBody(
          key: ValueKey<String>('planner-${view.periodKey}'),
          view: view,
        );
      },
    );
  }
}

/// The stateful editor for one planning day's three named sections. Its
/// controllers are seeded from the persisted record and owned for the lifetime
/// of the day's [ValueKey], so switching days rebuilds them cleanly.
final class _PlannerDailyBody extends ConsumerStatefulWidget {
  const _PlannerDailyBody({required this.view, super.key});

  final PlannerDailyView view;

  @override
  ConsumerState<_PlannerDailyBody> createState() => _PlannerDailyBodyState();
}

class _PlannerDailyBodyState extends ConsumerState<_PlannerDailyBody> {
  late final TextEditingController _morning;
  late final TextEditingController _daily;
  late final TextEditingController _evening;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _morning = TextEditingController(text: widget.view.morningPlanMd);
    _daily = TextEditingController(text: widget.view.dailyPlanMd);
    _evening = TextEditingController(text: widget.view.eveningReflectionMd);
  }

  @override
  void dispose() {
    _morning.dispose();
    _daily.dispose();
    _evening.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await ref
        .read(plannerActionsProvider.notifier)
        .saveDaily(
          lifeAreaId: widget.view.lifeAreaId,
          periodKey: widget.view.periodKey,
          morningPlanMd: _morning.text,
          dailyPlanMd: _daily.text,
          eveningReflectionMd: _evening.text,
        );
    if (mounted) {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    return FocusTraversalGroup(
      child: Semantics(
        label: l10n.plannerFormLabel,
        child: ListView(
          restorationId: 'content-planner',
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
                        l10n.plannerDailyTitle,
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                    const SizedBox(height: ForgeSpacing.xxs),
                    Text(
                      l10n.plannerPlanningDate(widget.view.periodKey),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: ForgeSpacing.lg),
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
}

/// One labelled, multiline free-text section. The label carries the meaning so
/// the field is understandable without color (NFR-A11Y-001/003).
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
