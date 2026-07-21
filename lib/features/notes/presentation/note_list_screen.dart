import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/notes/domain/note.dart';
import 'package:forge/features/notes/domain/note_repository.dart';
import 'package:forge/features/notes/presentation/note_labels.dart';
import 'package:forge/features/notes/presentation/note_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

/// The accessible, adaptive notes list (R-NOTE-002).
///
/// One screen renders the All, Pinned, Archived and Trash views, switched by
/// view chips. New notes are created title-first and open straight into the
/// Markdown editor. Pin/archive/delete run through the durable command and
/// deletion contracts with immediate Undo for reversible actions (R-GEN-003).
/// All content is reconstructed from the local generation, so it is available
/// offline (R-GEN-001).
final class NoteListScreen extends ConsumerWidget {
  const NoteListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<Note>> notes = ref.watch(noteListProvider);
    final NoteViewKind view = ref.watch(noteViewProvider);

    ref.listen<NoteFeedback>(noteActionsProvider, (_, NoteFeedback next) {
      _handleFeedback(context, ref, next);
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
              onPressed: () => _createNote(context, ref),
              icon: const Icon(Icons.add),
              label: Text(l10n.noteNew),
            ),
          ),
        ),
        const SizedBox(height: ForgeSpacing.xs),
        _ViewChips(view: view),
        const Divider(height: 1),
        Expanded(
          child: notes.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (Object error, _) =>
                Center(child: Text(l10n.errorUnexpected)),
            data: (List<Note> list) => _buildList(context, ref, view, list),
          ),
        ),
      ],
    );
  }

  Widget _buildList(
    BuildContext context,
    WidgetRef ref,
    NoteViewKind view,
    List<Note> list,
  ) {
    final AppLocalizations l10n = context.l10n;
    if (!ref.read(notesConfiguredProvider)) {
      return _EmptyView(message: l10n.notesUnavailable);
    }
    if (list.isEmpty) {
      return _EmptyView(message: _emptyMessage(l10n, view));
    }
    return FocusTraversalGroup(
      child: Semantics(
        label: l10n.notesListLabel,
        child: ListView.separated(
          restorationId: 'content-notes-${view.name}',
          padding: const EdgeInsets.symmetric(
            horizontal: ForgeSpacing.xs,
            vertical: ForgeSpacing.xs,
          ),
          itemCount: list.length,
          separatorBuilder: (_, _) => const SizedBox(height: ForgeSpacing.xxs),
          itemBuilder: (BuildContext context, int index) {
            final Note note = list[index];
            return ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: ForgeSizes.readableContentMaxWidth,
              ),
              child: _NoteTile(
                key: ValueKey<String>('note-${note.id.value}'),
                note: note,
                trashed: view == NoteViewKind.trash,
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _createNote(BuildContext context, WidgetRef ref) async {
    final AppLocalizations l10n = context.l10n;
    final String? title = await _promptTitle(context, l10n);
    if (title == null || title.trim().isEmpty) {
      return;
    }
    final String? id = await ref
        .read(noteActionsProvider.notifier)
        .create(title: title.trim());
    if (id != null && context.mounted) {
      unawaited(context.push('/notes/$id'));
    }
  }

  Future<String?> _promptTitle(BuildContext context, AppLocalizations l10n) =>
      showDialog<String>(
        context: context,
        builder: (BuildContext context) => const _TitlePromptDialog(),
      );

  String _emptyMessage(AppLocalizations l10n, NoteViewKind view) =>
      switch (view) {
        NoteViewKind.all => l10n.notesEmptyAll,
        NoteViewKind.pinned => l10n.notesEmptyPinned,
        NoteViewKind.archived => l10n.notesEmptyArchived,
        NoteViewKind.trash => l10n.notesEmptyTrash,
      };

  void _handleFeedback(
    BuildContext context,
    WidgetRef ref,
    NoteFeedback feedback,
  ) {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    switch (feedback) {
      case NoteFeedbackNone():
        return;
      case NoteFeedbackUndo(offer: final NoteUndo offer):
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text(l10n.noteUndoDeleted),
            action: SnackBarAction(
              label: l10n.actionUndo,
              onPressed: () => unawaited(offer.undo()),
            ),
          ),
        );
      case NoteFeedbackError(failure: final failure):
        messenger.showSnackBar(
          SnackBar(content: Text(NoteLabels.failure(l10n, failure.code))),
        );
    }
    ref.read(noteActionsProvider.notifier).dismiss();
  }
}

final class _ViewChips extends ConsumerWidget {
  const _ViewChips({required this.view});

  final NoteViewKind view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: ForgeSpacing.md),
      child: Row(
        children: <Widget>[
          for (final (NoteViewKind kind, String label)
              in <(NoteViewKind, String)>[
                (NoteViewKind.all, l10n.noteViewAll),
                (NoteViewKind.pinned, l10n.noteViewPinned),
                (NoteViewKind.archived, l10n.noteViewArchived),
                (NoteViewKind.trash, l10n.noteViewTrash),
              ])
            Padding(
              padding: const EdgeInsets.only(right: ForgeSpacing.xs),
              child: ChoiceChip(
                label: Text(label),
                selected: view == kind,
                onSelected: (_) =>
                    ref.read(noteViewProvider.notifier).set(kind),
              ),
            ),
        ],
      ),
    );
  }
}

final class _NoteTile extends ConsumerWidget {
  const _NoteTile({required this.note, required this.trashed, super.key});

  final Note note;
  final bool trashed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final NoteActionsController actions = ref.read(
      noteActionsProvider.notifier,
    );
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        title: Text(note.title),
        subtitle: _subtitle(context, l10n),
        onTap: trashed ? null : () => context.push('/notes/${note.id.value}'),
        trailing: trashed
            ? IconButton(
                icon: const Icon(Icons.restore_from_trash),
                tooltip: l10n.noteRestore,
                onPressed: () => unawaited(actions.restore(note.id.value)),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    icon: Icon(
                      note.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                    ),
                    tooltip: note.pinned ? l10n.noteUnpin : l10n.notePin,
                    onPressed: () => unawaited(
                      actions.setPinned(note.id.value, pinned: !note.pinned),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      note.isArchived
                          ? Icons.unarchive_outlined
                          : Icons.archive_outlined,
                    ),
                    tooltip: note.isArchived
                        ? l10n.noteUnarchive
                        : l10n.noteArchive,
                    onPressed: () => unawaited(
                      actions.setArchived(
                        note.id.value,
                        archived: !note.isArchived,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: l10n.noteDelete,
                    onPressed: () =>
                        unawaited(actions.softDelete(note.id.value)),
                  ),
                ],
              ),
      ),
    );
  }

  Widget? _subtitle(BuildContext context, AppLocalizations l10n) {
    final List<String> badges = <String>[
      if (note.pinned) l10n.notePinnedBadge,
      if (note.isArchived) l10n.noteArchivedBadge,
      if (note.isDeleted) l10n.noteDeletedBadge,
    ];
    if (badges.isEmpty) {
      return null;
    }
    return Text(badges.join(' · '));
  }
}

/// A small stateful dialog that owns its title controller so the controller is
/// only disposed after the dialog route is fully gone (avoids using a disposed
/// controller during the pop animation).
final class _TitlePromptDialog extends StatefulWidget {
  const _TitlePromptDialog();

  @override
  State<_TitlePromptDialog> createState() => _TitlePromptDialogState();
}

class _TitlePromptDialogState extends State<_TitlePromptDialog> {
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
      title: Text(l10n.noteCreateTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: l10n.noteCreateTitleLabel,
          hintText: l10n.noteCreateTitleHint,
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
          child: Text(l10n.noteCreate),
        ),
      ],
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
