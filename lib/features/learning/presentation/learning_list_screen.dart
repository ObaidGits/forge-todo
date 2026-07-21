import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/ui/forge_empty_state.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/learning/domain/learning_resource_type.dart';
import 'package:forge/features/learning/presentation/learning_labels.dart';
import 'package:forge/features/learning/presentation/learning_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

/// The accessible, adaptive Learning Resources list (R-LEARN-001, R-LEARN-004).
///
/// One screen renders every non-deleted Learning Resource for the active
/// profile with its title, type, status, and transparent derived-or-manual
/// progress. New resources are created title-first (with a type) and open
/// straight into the resource screen. Content is reconstructed from the local
/// generation, so it is available offline (R-GEN-001). Learning presents a
/// single "Learning Resource" umbrella; the internal `course` table name is
/// never surfaced to the user.
final class LearningListScreen extends ConsumerWidget {
  const LearningListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<LearningResourceView>> resources = ref.watch(
      learningListProvider,
    );

    ref.listen<LearningFeedback>(learningActionsProvider, (
      _,
      LearningFeedback next,
    ) {
      if (next is LearningFeedbackError) {
        final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(SnackBar(content: Text(l10n.errorUnexpected)));
        ref.read(learningActionsProvider.notifier).dismiss();
      }
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ForgeSpacing.md,
            ForgeSpacing.sm,
            ForgeSpacing.md,
            0,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: ref.watch(learningDefaultAreaProvider) == null
                  ? null
                  : () => unawaited(_create(context, ref)),
              icon: const Icon(Icons.add),
              label: Text(l10n.learnNew),
            ),
          ),
        ),
        const SizedBox(height: ForgeSpacing.xs),
        const Divider(height: 1),
        Expanded(
          child: resources.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object error, _) =>
                Center(child: Text(l10n.errorUnexpected)),
            data: (List<LearningResourceView> list) =>
                _buildList(context, ref, list),
          ),
        ),
      ],
    );
  }

  Widget _buildList(
    BuildContext context,
    WidgetRef ref,
    List<LearningResourceView> list,
  ) {
    final AppLocalizations l10n = context.l10n;
    if (!ref.read(learningConfiguredProvider)) {
      return ForgeEmptyState(
        icon: Icons.school_outlined,
        title: l10n.navLearn,
        body: l10n.learningUnavailable,
      );
    }
    if (list.isEmpty) {
      return ForgeEmptyState(
        icon: Icons.school_outlined,
        title: l10n.navLearn,
        body: l10n.learningEmpty,
      );
    }
    return FocusTraversalGroup(
      child: Semantics(
        label: l10n.learningListLabel,
        child: ListView.separated(
          restorationId: 'content-learn',
          padding: const EdgeInsets.symmetric(
            horizontal: ForgeSpacing.xs,
            vertical: ForgeSpacing.xs,
          ),
          itemCount: list.length,
          separatorBuilder: (_, _) => const SizedBox(height: ForgeSpacing.xxs),
          itemBuilder: (BuildContext context, int index) {
            final LearningResourceView view = list[index];
            return ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: ForgeSizes.readableContentMaxWidth,
              ),
              child: _ResourceTile(
                key: ValueKey<String>('learn-${view.resource.id.value}'),
                view: view,
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final LifeAreaId? area = ref.read(learningDefaultAreaProvider);
    if (area == null) {
      return;
    }
    final _CreateResult? result = await showDialog<_CreateResult>(
      context: context,
      builder: (BuildContext context) => const _CreateResourceDialog(),
    );
    if (result == null || result.title.trim().isEmpty) {
      return;
    }
    final String? id = await ref
        .read(learningActionsProvider.notifier)
        .create(
          title: result.title.trim(),
          type: result.type,
          lifeAreaId: area,
        );
    if (id != null && context.mounted) {
      unawaited(context.push('/learn/$id'));
    }
  }
}

final class _ResourceTile extends StatelessWidget {
  const _ResourceTile({required this.view, super.key});

  final LearningResourceView view;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final List<String> badges = <String>[
      LearningLabels.resourceType(l10n, view.resource.type),
      LearningLabels.status(l10n, view.resource.status),
      LearningLabels.progress(l10n, view.progress),
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        title: Text(view.resource.title),
        subtitle: Text(badges.join(' · ')),
        trailing: const Icon(Icons.chevron_right),
        onTap: () =>
            unawaited(context.push('/learn/${view.resource.id.value}')),
      ),
    );
  }
}

/// The title + type entered when creating a Learning Resource.
final class _CreateResult {
  const _CreateResult({required this.title, required this.type});
  final String title;
  final LearningResourceType type;
}

/// A small stateful dialog owning its title controller and selected type so
/// they are disposed only after the dialog route is fully gone.
final class _CreateResourceDialog extends StatefulWidget {
  const _CreateResourceDialog();

  @override
  State<_CreateResourceDialog> createState() => _CreateResourceDialogState();
}

class _CreateResourceDialogState extends State<_CreateResourceDialog> {
  final TextEditingController _controller = TextEditingController();
  LearningResourceType _type = LearningResourceType.course;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(
      context,
    ).pop(_CreateResult(title: _controller.text, type: _type));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.learnCreateTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.learnCreateTitleLabel,
              hintText: l10n.learnCreateTitleHint,
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: ForgeSpacing.md),
          DropdownButtonFormField<LearningResourceType>(
            initialValue: _type,
            decoration: InputDecoration(labelText: l10n.learnCreateTypeLabel),
            items: <DropdownMenuItem<LearningResourceType>>[
              for (final LearningResourceType type
                  in LearningResourceType.values)
                DropdownMenuItem<LearningResourceType>(
                  value: type,
                  child: Text(LearningLabels.resourceType(l10n, type)),
                ),
            ],
            onChanged: (LearningResourceType? value) {
              if (value != null) {
                setState(() => _type = value);
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
        FilledButton(onPressed: _submit, child: Text(l10n.learnCreate)),
      ],
    );
  }
}
