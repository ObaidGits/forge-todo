import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/ui/forge_empty_state.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/fitness/domain/body_measurement.dart';
import 'package:forge/features/fitness/domain/workout_session.dart';
import 'package:forge/features/fitness/domain/workout_template.dart';
import 'package:forge/features/fitness/presentation/fitness_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// The accessible, non-medical Fitness screen (R-FIT-001, R-FIT-002, R-FIT-004,
/// R-FIT-005).
///
/// One calm screen renders rank-ordered workout templates, recently logged
/// workouts, and body-weight measurements that preserve the exact value/unit a
/// person entered. Every record shown is the underlying factual record itself:
/// no health index, calorie estimate, or diagnostic interpretation is derived
/// (R-FIT-004, R-FIT-005). Create affordances map one-to-one onto the durable
/// command surface (create a template, log a workout, record a weight). Optional
/// water tracking is disabled by default and is intentionally omitted from this
/// screen (R-FIT-003). Content is reconstructed from the local generation, so it
/// is available offline (R-GEN-001).
///
/// Fitness has no navigation-rail tab; it is reached from the Settings hub.
final class FitnessScreen extends ConsumerWidget {
  const FitnessScreen({super.key});

  /// The mass units offered when recording a body-weight measurement. The
  /// entered unit is preserved verbatim (R-FIT-002).
  static const List<String> weightUnits = <String>['kg', 'lb', 'st', 'g'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;

    ref.listen<FitnessFeedback>(fitnessActionsProvider, (
      _,
      FitnessFeedback next,
    ) {
      if (next is FitnessFeedbackError) {
        final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(SnackBar(content: Text(l10n.errorUnexpected)));
        ref.read(fitnessActionsProvider.notifier).dismiss();
      }
    });

    if (!ref.watch(fitnessConfiguredProvider)) {
      return ForgeEmptyState(
        icon: Icons.fitness_center_outlined,
        title: l10n.fitnessTitle,
        body: l10n.fitnessUnavailable,
      );
    }

    final AsyncValue<FitnessOverview> overview = ref.watch(
      fitnessOverviewProvider,
    );
    return overview.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, _) => Center(child: Text(l10n.errorUnexpected)),
      data: (FitnessOverview data) => _OverviewView(overview: data),
    );
  }
}

final class _OverviewView extends ConsumerWidget {
  const _OverviewView({required this.overview});

  final FitnessOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final bool canCreate = ref.watch(fitnessDefaultAreaProvider) != null;

    return FocusTraversalGroup(
      child: ListView(
        restorationId: 'content-fitness',
        padding: const EdgeInsets.symmetric(vertical: ForgeSpacing.sm),
        children: <Widget>[
          _Section(
            title: l10n.fitnessSectionTemplates,
            actionLabel: l10n.fitnessNewTemplate,
            onAction: canCreate
                ? () => unawaited(_createTemplate(context, ref))
                : null,
            emptyMessage: l10n.fitnessTemplatesEmpty,
            isEmpty: overview.templates.isEmpty,
            children: <Widget>[
              for (final WorkoutTemplate template in overview.templates)
                _TemplateTile(
                  key: ValueKey<String>(
                    'fitness-template-${template.id.value}',
                  ),
                  template: template,
                ),
            ],
          ),
          const Divider(),
          _Section(
            title: l10n.fitnessSectionSessions,
            actionLabel: l10n.fitnessLogWorkout,
            onAction: canCreate
                ? () => unawaited(_logWorkout(context, ref))
                : null,
            emptyMessage: l10n.fitnessSessionsEmpty,
            isEmpty: overview.sessions.isEmpty,
            children: <Widget>[
              for (final WorkoutSession session in overview.sessions)
                _SessionTile(
                  key: ValueKey<String>('fitness-session-${session.id.value}'),
                  session: session,
                ),
            ],
          ),
          const Divider(),
          _Section(
            title: l10n.fitnessSectionBodyWeight,
            actionLabel: l10n.fitnessRecordWeight,
            onAction: canCreate
                ? () => unawaited(_recordWeight(context, ref))
                : null,
            emptyMessage: l10n.fitnessBodyWeightEmpty,
            isEmpty: overview.measurements.isEmpty,
            children: <Widget>[
              for (final BodyMeasurement measurement in overview.measurements)
                _MeasurementTile(
                  key: ValueKey<String>(
                    'fitness-weight-${measurement.id.value}',
                  ),
                  measurement: measurement,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _createTemplate(BuildContext context, WidgetRef ref) async {
    final LifeAreaId? area = ref.read(fitnessDefaultAreaProvider);
    if (area == null) {
      return;
    }
    final AppLocalizations l10n = context.l10n;
    final String? title = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _TextPromptDialog(
        title: l10n.fitnessCreateTemplateTitle,
        fieldLabel: l10n.fitnessTemplateTitleLabel,
        fieldHint: l10n.fitnessTemplateTitleHint,
        confirmLabel: l10n.fitnessCreate,
      ),
    );
    if (title == null || title.trim().isEmpty) {
      return;
    }
    await ref
        .read(fitnessActionsProvider.notifier)
        .createTemplate(title: title.trim(), lifeAreaId: area);
  }

  Future<void> _logWorkout(BuildContext context, WidgetRef ref) async {
    final LifeAreaId? area = ref.read(fitnessDefaultAreaProvider);
    if (area == null) {
      return;
    }
    final AppLocalizations l10n = context.l10n;
    final String? title = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _TextPromptDialog(
        title: l10n.fitnessLogWorkoutTitle,
        fieldLabel: l10n.fitnessWorkoutTitleLabel,
        fieldHint: l10n.fitnessWorkoutTitleHint,
        confirmLabel: l10n.fitnessLogWorkout,
      ),
    );
    if (title == null || title.trim().isEmpty) {
      return;
    }
    await ref
        .read(fitnessActionsProvider.notifier)
        .logSession(title: title.trim(), lifeAreaId: area);
  }

  Future<void> _recordWeight(BuildContext context, WidgetRef ref) async {
    final LifeAreaId? area = ref.read(fitnessDefaultAreaProvider);
    if (area == null) {
      return;
    }
    final _WeightResult? result = await showDialog<_WeightResult>(
      context: context,
      builder: (BuildContext context) => const _RecordWeightDialog(),
    );
    if (result == null) {
      return;
    }
    await ref
        .read(fitnessActionsProvider.notifier)
        .recordBodyWeight(
          value: result.value,
          unit: result.unit,
          lifeAreaId: area,
        );
  }
}

/// A titled section with an optional single create action and an accessible
/// empty state, followed by its rows.
final class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.actionLabel,
    required this.onAction,
    required this.emptyMessage,
    required this.isEmpty,
    required this.children,
  });

  final String title;
  final String actionLabel;
  final VoidCallback? onAction;
  final String emptyMessage;
  final bool isEmpty;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
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
          child: Row(
            children: <Widget>[
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              const SizedBox(width: ForgeSpacing.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: ForgeSizes.minimumInteractiveDimension,
                ),
                child: TextButton.icon(
                  onPressed: onAction,
                  icon: const Icon(Icons.add),
                  label: Text(actionLabel),
                ),
              ),
            ],
          ),
        ),
        if (isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: ForgeSpacing.md),
            child: ForgeEmptyState(
              compact: true,
              title: '',
              body: emptyMessage,
            ),
          )
        else
          ...children,
      ],
    );
  }
}

final class _TemplateTile extends StatelessWidget {
  const _TemplateTile({required this.template, super.key});

  final WorkoutTemplate template;

  @override
  Widget build(BuildContext context) {
    return _RowCard(title: template.title, subtitle: null);
  }
}

final class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, super.key});

  final WorkoutSession session;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return _RowCard(
      title: session.title,
      subtitle: l10n.fitnessLoggedOn(_formatDate(session.startedAtUtc)),
    );
  }
}

final class _MeasurementTile extends StatelessWidget {
  const _MeasurementTile({required this.measurement, super.key});

  final BodyMeasurement measurement;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    // The entered value and unit are shown exactly as recorded (R-FIT-002).
    final String value =
        '${_formatValue(measurement.value.enteredValue)} '
        '${measurement.value.enteredUnit}';
    return _RowCard(
      title: value,
      subtitle: l10n.fitnessMeasuredOn(_formatDate(measurement.measuredAtUtc)),
    );
  }
}

/// A shared accessible row: a card wrapping a list tile that meets the minimum
/// touch-target height. The text carries the meaning, never colour alone
/// (NFR-A11Y-001, NFR-A11Y-003).
final class _RowCard extends StatelessWidget {
  const _RowCard({required this.title, required this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ForgeSpacing.xs,
        vertical: ForgeSpacing.xxs,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: ForgeSizes.readableContentMaxWidth,
          minHeight: ForgeSizes.minimumInteractiveDimension,
        ),
        child: Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            title: Text(title),
            subtitle: subtitle == null ? null : Text(subtitle!),
          ),
        ),
      ),
    );
  }
}

/// The value + unit entered when recording a body-weight measurement.
final class _WeightResult {
  const _WeightResult({required this.value, required this.unit});
  final num value;
  final String unit;
}

/// A small stateful dialog owning its title controller so it is disposed only
/// after the dialog route is fully gone.
final class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.fieldLabel,
    required this.fieldHint,
    required this.confirmLabel,
  });

  final String title;
  final String fieldLabel;
  final String fieldHint;
  final String confirmLabel;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.fieldLabel,
          hintText: widget.fieldHint,
        ),
        onSubmitted: (String value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.dialogCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// A small stateful dialog capturing a body-weight value and its unit. The
/// entered value/unit pair is preserved verbatim by the command service
/// (R-FIT-002).
final class _RecordWeightDialog extends StatefulWidget {
  const _RecordWeightDialog();

  @override
  State<_RecordWeightDialog> createState() => _RecordWeightDialogState();
}

class _RecordWeightDialogState extends State<_RecordWeightDialog> {
  final TextEditingController _controller = TextEditingController();
  String _unit = FitnessScreen.weightUnits.first;
  bool _invalid = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final num? value = num.tryParse(_controller.text.trim());
    if (value == null || value < 0) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.of(context).pop(_WeightResult(value: value, unit: _unit));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.fitnessRecordWeightTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l10n.fitnessWeightValueLabel,
              hintText: l10n.fitnessWeightValueHint,
              errorText: _invalid ? l10n.fitnessWeightInvalid : null,
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: ForgeSpacing.md),
          DropdownButtonFormField<String>(
            initialValue: _unit,
            decoration: InputDecoration(labelText: l10n.fitnessWeightUnitLabel),
            items: <DropdownMenuItem<String>>[
              for (final String unit in FitnessScreen.weightUnits)
                DropdownMenuItem<String>(value: unit, child: Text(unit)),
            ],
            onChanged: (String? value) {
              if (value != null) {
                setState(() => _unit = value);
              }
            },
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.dialogCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.fitnessSave)),
      ],
    );
  }
}

/// Formats a numeric value without trailing decimals for whole numbers, so a
/// recorded `80` shows as `80` and `80.5` shows as `80.5` (R-FIT-002 preserves
/// the entered value; this only trims a redundant `.0`).
String _formatValue(num value) {
  if (value is int || value == value.roundToDouble()) {
    return value.toInt().toString();
  }
  return value.toString();
}

/// Formats a UTC-micros instant as a plain `YYYY-MM-DD` date. No medical or
/// derived interpretation is attached (R-FIT-004, R-FIT-005).
String _formatDate(int utcMicros) {
  final DateTime dt = DateTime.fromMicrosecondsSinceEpoch(
    utcMicros,
    isUtc: true,
  );
  final String month = dt.month.toString().padLeft(2, '0');
  final String day = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$month-$day';
}
