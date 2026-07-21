import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/areas/application/life_area_query_service.dart';
import 'package:forge/features/areas/presentation/area_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// Life Area management: create, rename, reorder, archive, and choose the
/// default area (R-GEN-002).
///
/// Content is reconstructed from the active local generation, so it is
/// available offline (R-GEN-001). Every durable change is committed through the
/// command bus (R-GEN-005). The surface is fully keyboard operable and every
/// control carries an accessible name (NFR-A11Y-001).
final class LifeAreaManagementScreen extends ConsumerStatefulWidget {
  const LifeAreaManagementScreen({super.key});

  @override
  ConsumerState<LifeAreaManagementScreen> createState() =>
      _LifeAreaManagementScreenState();
}

class _LifeAreaManagementScreenState
    extends ConsumerState<LifeAreaManagementScreen> {
  bool _showArchived = true;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<LifeAreaSummary>> areas = ref.watch(
      lifeAreaListProvider,
    );

    ref.listen<AreaFeedback>(areaActionsProvider, (_, AreaFeedback next) {
      _handleFeedback(context, l10n, next);
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
          child: Row(
            children: <Widget>[
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    l10n.areasTitle,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: ForgeSizes.minimumInteractiveDimension,
                  minHeight: ForgeSizes.minimumInteractiveDimension,
                ),
                child: IconButton(
                  onPressed: ref.watch(areasConfiguredProvider)
                      ? () => _openCreateDialog(context, l10n)
                      : null,
                  tooltip: l10n.areaAdd,
                  icon: const Icon(Icons.add),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: areas.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object error, _) =>
                Center(child: Text(l10n.errorUnexpected)),
            data: (List<LifeAreaSummary> list) =>
                _buildBody(context, l10n, list),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    List<LifeAreaSummary> all,
  ) {
    if (!ref.read(areasConfiguredProvider)) {
      return _EmptyView(message: l10n.areasUnavailable);
    }
    final List<LifeAreaSummary> visible = _showArchived
        ? all
        : all.where((LifeAreaSummary a) => !a.isArchived).toList();
    final bool hasArchived = all.any((LifeAreaSummary a) => a.isArchived);
    if (visible.isEmpty && !hasArchived) {
      return _EmptyView(message: l10n.areasEmpty);
    }
    return FocusTraversalGroup(
      child: Semantics(
        label: l10n.areasListLabel,
        child: ListView(
          restorationId: 'content-life-areas',
          padding: const EdgeInsets.all(ForgeSpacing.xs),
          children: <Widget>[
            for (int i = 0; i < visible.length; i++)
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: ForgeSizes.readableContentMaxWidth,
                ),
                child: _AreaRow(
                  area: visible[i],
                  canMoveUp: i > 0,
                  canMoveDown: i < visible.length - 1,
                  onMoveUp: () => _move(visible, i, up: true),
                  onMoveDown: () => _move(visible, i, up: false),
                  onRename: () => _openRenameDialog(context, l10n, visible[i]),
                  onArchive: () => unawaited(
                    ref
                        .read(areaActionsProvider.notifier)
                        .archive(visible[i].id.value),
                  ),
                  onRestore: () => unawaited(
                    ref
                        .read(areaActionsProvider.notifier)
                        .restore(visible[i].id.value),
                  ),
                  onMakeDefault: () => unawaited(
                    ref
                        .read(areaActionsProvider.notifier)
                        .makeDefault(visible[i].id.value),
                  ),
                ),
              ),
            if (hasArchived)
              Padding(
                padding: const EdgeInsets.all(ForgeSpacing.sm),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () =>
                        setState(() => _showArchived = !_showArchived),
                    icon: Icon(
                      _showArchived ? Icons.visibility_off : Icons.visibility,
                    ),
                    label: Text(
                      _showArchived
                          ? l10n.areaHideArchived
                          : l10n.areaShowArchived,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Moves the area at [index] within [ordered] one position [up] or down by
  /// re-ranking it strictly between its new neighbours (R-GEN-002). Neighbour
  /// ranks are never rewritten.
  void _move(List<LifeAreaSummary> ordered, int index, {required bool up}) {
    if (up) {
      final String? before = index >= 2 ? ordered[index - 2].rank : null;
      final String after = ordered[index - 1].rank;
      unawaited(
        ref
            .read(areaActionsProvider.notifier)
            .reorder(
              areaId: ordered[index].id.value,
              beforeRank: before,
              afterRank: after,
            ),
      );
    } else {
      final String before = ordered[index + 1].rank;
      final String? after = index + 2 < ordered.length
          ? ordered[index + 2].rank
          : null;
      unawaited(
        ref
            .read(areaActionsProvider.notifier)
            .reorder(
              areaId: ordered[index].id.value,
              beforeRank: before,
              afterRank: after,
            ),
      );
    }
  }

  Future<void> _openCreateDialog(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final String? name = await _promptForName(
      context,
      title: l10n.areaAddTitle,
      confirmLabel: l10n.areaCreateConfirm,
    );
    if (name != null && name.isNotEmpty) {
      await ref.read(areaActionsProvider.notifier).create(name: name);
    }
  }

  Future<void> _openRenameDialog(
    BuildContext context,
    AppLocalizations l10n,
    LifeAreaSummary area,
  ) async {
    final String? name = await _promptForName(
      context,
      title: l10n.areaRenameTitle,
      confirmLabel: l10n.areaRenameConfirm,
      initialValue: area.name,
    );
    if (name != null && name.isNotEmpty && name != area.name) {
      await ref
          .read(areaActionsProvider.notifier)
          .rename(areaId: area.id.value, name: name);
    }
  }

  Future<String?> _promptForName(
    BuildContext context, {
    required String title,
    required String confirmLabel,
    String initialValue = '',
  }) {
    return showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => _NameDialog(
        title: title,
        confirmLabel: confirmLabel,
        initialValue: initialValue,
      ),
    );
  }

  void _handleFeedback(
    BuildContext context,
    AppLocalizations l10n,
    AreaFeedback feedback,
  ) {
    final String? message = switch (feedback) {
      AreaFeedbackNone() => null,
      AreaFeedbackMessage(messageCode: final String code) => _messageFor(
        l10n,
        code,
      ),
      AreaFeedbackError(failure: final Failure failure) => _errorFor(
        l10n,
        failure,
      ),
    };
    if (message == null) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
    ref.read(areaActionsProvider.notifier).dismiss();
  }

  String _messageFor(AppLocalizations l10n, String code) => switch (code) {
    'areaCreated' => l10n.areaCreated,
    'areaRenamed' => l10n.areaRenamed,
    'areaReordered' => l10n.areaReordered,
    'areaArchived' => l10n.areaArchived,
    'areaRestored' => l10n.areaRestored,
    'areaDefaultSet' => l10n.areaDefaultSet,
    _ => l10n.areaCreated,
  };

  String _errorFor(AppLocalizations l10n, Failure failure) =>
      switch (failure.code) {
        'area.duplicate_name' => l10n.errorAreaDuplicate,
        'area.default_cannot_archive' => l10n.errorAreaDefaultArchive,
        'area.not_found' => l10n.errorAreaNotFound,
        'areas.unavailable' => l10n.areasUnavailable,
        _ => l10n.errorAreaInvalid,
      };
}

/// A small name-entry dialog that owns its [TextEditingController] so the
/// controller is disposed only after the dialog's exit transition completes.
final class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.confirmLabel,
    required this.initialValue,
  });

  final String title;
  final String confirmLabel;
  final String initialValue;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(_controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          maxLength: 60,
          decoration: InputDecoration(
            labelText: l10n.areaNameLabel,
            hintText: l10n.areaNameHint,
          ),
          validator: (String? value) => (value == null || value.trim().isEmpty)
              ? l10n.areaNameRequired
              : null,
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.dialogCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

final class _AreaRow extends StatelessWidget {
  const _AreaRow({
    required this.area,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRename,
    required this.onArchive,
    required this.onRestore,
    required this.onMakeDefault,
  });

  final LifeAreaSummary area;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onRename;
  final VoidCallback onArchive;
  final VoidCallback onRestore;
  final VoidCallback onMakeDefault;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ForgeSpacing.xxs),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: ForgeSizes.minimumInteractiveDimension,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(area.name, style: theme.textTheme.titleMedium),
                  if (area.isDefault || area.isArchived)
                    Padding(
                      padding: const EdgeInsets.only(top: ForgeSpacing.xxs),
                      child: Wrap(
                        spacing: ForgeSpacing.xs,
                        children: <Widget>[
                          if (area.isDefault)
                            _Badge(label: l10n.areaDefaultBadge),
                          if (area.isArchived)
                            _Badge(label: l10n.areaArchivedBadge),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              onPressed: canMoveUp ? onMoveUp : null,
              tooltip: l10n.areaMoveUp(area.name),
              icon: const Icon(Icons.keyboard_arrow_up),
            ),
            IconButton(
              onPressed: canMoveDown ? onMoveDown : null,
              tooltip: l10n.areaMoveDown(area.name),
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
            PopupMenuButton<String>(
              tooltip: l10n.areaMoreActions(area.name),
              onSelected: (String value) {
                switch (value) {
                  case 'rename':
                    onRename();
                  case 'default':
                    onMakeDefault();
                  case 'archive':
                    onArchive();
                  case 'restore':
                    onRestore();
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'rename',
                  child: Text(l10n.areaRename),
                ),
                if (!area.isDefault && !area.isArchived)
                  PopupMenuItem<String>(
                    value: 'default',
                    child: Text(l10n.areaMakeDefault),
                  ),
                if (!area.isArchived)
                  PopupMenuItem<String>(
                    value: 'archive',
                    child: Text(l10n.areaArchive),
                  ),
                if (area.isArchived)
                  PopupMenuItem<String>(
                    value: 'restore',
                    child: Text(l10n.areaRestore),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: ForgeSpacing.xs,
        vertical: ForgeSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(ForgeRadii.control),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
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
