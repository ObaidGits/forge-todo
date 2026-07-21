import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/routing/uri_policy.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/notes/application/note_commands.dart';
import 'package:forge/features/notes/application/note_draft_journal.dart';
import 'package:forge/features/notes/domain/note.dart';
import 'package:forge/features/notes/domain/note_repository.dart';
import 'package:forge/features/notes/presentation/markdown_editing.dart';
import 'package:forge/features/notes/presentation/note_labels.dart';
import 'package:forge/features/notes/presentation/note_providers.dart';
import 'package:forge/features/notes/presentation/widgets/markdown_preview.dart';
import 'package:forge/features/notes/presentation/widgets/markdown_toolbar.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

/// The accessible, adaptive Markdown editor + preview for a single note
/// (R-NOTE-001, R-NOTE-005, R-SEC-005, NFR-A11Y-001/002/003).
///
/// It loads the canonical note by id, offers edit and preview modes over the
/// same body, a formatting toolbar with equivalent keyboard commands, rendered
/// preview through the safe renderer, link opening routed through the central
/// [UriPolicy], debounced autosave to the encrypted draft journal with
/// crash/restart recovery, and bounded rendering for very large notes.
final class NoteEditorScreen extends ConsumerWidget {
  const NoteEditorScreen({required this.noteId, super.key});

  final String noteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    if (!ref.watch(notesConfiguredProvider)) {
      return _NotFound(message: l10n.notesUnavailable);
    }
    final AsyncValue<Note?> note = ref.watch(noteDetailProvider(noteId));
    return note.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, _) => Center(child: Text(l10n.errorUnexpected)),
      data: (Note? value) {
        if (value == null) {
          return _NotFound(message: l10n.noteNotFound);
        }
        return _NoteEditorBody(
          key: ValueKey<String>(value.id.value),
          note: value,
        );
      },
    );
  }
}

enum _Mode { edit, preview }

final class _NoteEditorBody extends ConsumerStatefulWidget {
  const _NoteEditorBody({required this.note, super.key});

  final Note note;

  @override
  ConsumerState<_NoteEditorBody> createState() => _NoteEditorBodyState();
}

class _NoteEditorBodyState extends ConsumerState<_NoteEditorBody>
    with WidgetsBindingObserver {
  late final TextEditingController _title;
  late final TextEditingController _body;
  final FocusNode _bodyFocus = FocusNode();

  _Mode _mode = _Mode.edit;
  bool _saving = false;
  bool _dirty = false;
  int _baseRevision = 1;
  Timer? _debounceTimer;

  // Provider values captured for safe use in dispose(), where `ref` is unsafe
  // (Riverpod forbids reading providers after the element is deactivated).
  NoteDraftJournal? _journal;
  ProfileId? _profile;
  Duration _debounceDuration = const Duration(milliseconds: 800);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _title = TextEditingController(text: widget.note.title);
    _body = TextEditingController(text: widget.note.body);
    _baseRevision = widget.note.revision;
    _body.addListener(_onBodyChanged);
    // Offer crash/restart recovery once the first frame is up (R-NOTE-005).
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeOfferRecovery());
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    // Flush any pending edit to the durable draft journal on navigation away
    // (R-NOTE-005). Fire-and-forget: the write is a local transaction. Uses the
    // captured fields because `ref` is unsafe once the element is deactivated.
    _flushDraft();
    WidgetsBinding.instance.removeObserver(this);
    _body.removeListener(_onBodyChanged);
    _title.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On background, flush and mark the draft as the authoritative unsaved copy
    // so editor memory can be discarded safely (R-NOTE-005).
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _flushDraft(markAwaitingRecovery: true);
    }
  }

  void _onBodyChanged() {
    if (!_dirty) {
      setState(() => _dirty = true);
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDuration, _flushDraft);
  }

  void _flushDraft({bool markAwaitingRecovery = false}) {
    if (!_dirty) {
      return;
    }
    final NoteDraftJournal? journal = _journal;
    final ProfileId? profile = _profile;
    if (journal == null || profile == null) {
      return;
    }
    unawaited(
      journal.save(
        profileId: profile,
        noteId: widget.note.id,
        baseRevision: _baseRevision,
        body: _body.text,
        markAwaitingRecovery: markAwaitingRecovery,
      ),
    );
  }

  Future<void> _maybeOfferRecovery() async {
    final NoteDraftJournal? journal = ref.read(notesDraftJournalProvider);
    final ProfileId? profile = ref.read(notesProfileProvider);
    if (journal == null || profile == null || !mounted) {
      return;
    }
    final draft = await journal.load(
      profileId: profile,
      noteId: widget.note.id,
    );
    if (!mounted || draft == null || draft.body == _body.text) {
      return;
    }
    final AppLocalizations l10n = context.l10n;
    final bool? recover = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(l10n.noteRecoveryTitle),
        content: Text(l10n.noteRecoveryBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.noteRecoveryDiscard),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.noteRecoveryRestore),
          ),
        ],
      ),
    );
    if (!mounted) {
      return;
    }
    if (recover ?? false) {
      _body.text = draft.body;
      setState(() => _dirty = true);
    } else {
      await journal.discard(profileId: profile, noteId: widget.note.id);
    }
  }

  Future<void> _save() async {
    final AppLocalizations l10n = context.l10n;
    final commands = ref.read(notesCommandServiceProvider);
    final ProfileId? profile = ref.read(notesProfileProvider);
    if (commands == null || profile == null) {
      _showMessage(NoteLabels.failure(l10n, 'notes.unavailable'));
      return;
    }
    if (_title.text.trim().isEmpty) {
      _showMessage(l10n.noteTitleRequired);
      return;
    }
    setState(() => _saving = true);
    _debounceTimer?.cancel();
    final Result<CommittedCommandResult> result = await commands.update(
      commandId: ref.read(notesCommandIdFactoryProvider)(),
      profileId: profile,
      noteId: widget.note.id,
      input: UpdateNoteInput(title: _title.text.trim(), body: _body.text),
    );
    if (!mounted) {
      return;
    }
    setState(() => _saving = false);
    switch (result) {
      case Success<CommittedCommandResult>():
        // A successful save removes the draft and advances the base revision so
        // subsequent autosaves pin the new exact base (R-NOTE-005).
        setState(() {
          _dirty = false;
          _baseRevision += 1;
        });
        ref.invalidate(noteDetailProvider(widget.note.id.value));
        ref.invalidate(noteListProvider);
        _showMessage(l10n.noteEditorSaved);
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        _showMessage(
          failure.code == 'note.not_found' || failure.kind.name == 'storage'
              ? l10n.noteSaveError
              : NoteLabels.failure(l10n, failure.code),
        );
    }
  }

  void _applyCommand(MarkdownCommand command) {
    final AppLocalizations l10n = context.l10n;
    if (command == MarkdownCommand.link) {
      unawaited(_promptLink(l10n));
      return;
    }
    final MarkdownEditState next = MarkdownEditing.apply(
      command,
      MarkdownEditState.fromValue(_body.value),
    );
    _body.value = next.toValue();
    _bodyFocus.requestFocus();
  }

  Future<void> _promptLink(AppLocalizations l10n) async {
    final MarkdownEditState before = MarkdownEditState.fromValue(_body.value);
    final String? url = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => const _LinkUrlDialog(),
    );
    if (!mounted || url == null) {
      return;
    }
    final MarkdownEditState next = MarkdownEditing.apply(
      MarkdownCommand.link,
      before,
      linkUrl: url.trim(),
    );
    _body.value = next.toValue();
    _bodyFocus.requestFocus();
  }

  Future<void> _openWikiLink(String target) async {
    final NoteRepository? repo = ref.read(notesRepositoryProvider);
    final ProfileId? profile = ref.read(notesProfileProvider);
    final AppLocalizations l10n = context.l10n;
    if (repo == null || profile == null) {
      return;
    }
    final List<Note> matches = await repo.findByNormalizedTitle(
      profile,
      target,
    );
    if (!mounted) {
      return;
    }
    if (matches.length == 1) {
      unawaited(context.push('/notes/${matches.single.id.value}'));
    } else if (matches.isEmpty) {
      _showMessage(l10n.noteWikiLinkUnresolved(target));
    } else {
      // Ambiguity selection is task 5.2; surface an honest prompt here.
      _showMessage(l10n.noteWikiLinkAmbiguous(target));
    }
  }

  Future<void> _openExternalLink(String href) async {
    final AppLocalizations l10n = context.l10n;
    final UriPolicy policy = ref.read(notesUriPolicyProvider);
    final Uri uri;
    try {
      uri = Uri.parse(href);
    } on FormatException {
      _showMessage(l10n.noteLinkBlocked);
      return;
    }
    // The tap is user-initiated; the policy still enforces scheme/host allowlist
    // (R-SEC-005). External links never open without passing the allowlist.
    final UriPolicyDecision decision = policy.evaluateOutbound(
      uri,
      userInitiated: true,
    );
    if (!decision.allowed || decision.canonicalUri == null) {
      _showMessage(l10n.noteLinkBlocked);
      return;
    }
    final bool confirmed = await _confirmExternal(l10n, decision.canonicalUri!);
    if (!confirmed || !mounted) {
      return;
    }
    final launcher = ref.read(notesLinkLauncherProvider);
    final bool opened = await launcher(decision.canonicalUri!);
    if (!mounted) {
      return;
    }
    if (!opened) {
      _showMessage(l10n.noteLinkOpenFailed);
    }
  }

  Future<bool> _confirmExternal(AppLocalizations l10n, Uri uri) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(l10n.noteLinkOpenTitle),
        content: Text(l10n.noteLinkOpenBody(uri.host)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.dialogCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.noteLinkOpen),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    // Capture provider values for safe use from dispose()/timers.
    _journal = ref.watch(notesDraftJournalProvider);
    _profile = ref.watch(notesProfileProvider);
    _debounceDuration = ref.watch(notesAutosaveDebounceProvider);
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
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _title,
                  textInputAction: TextInputAction.done,
                  style: theme.textTheme.titleLarge,
                  decoration: InputDecoration(
                    labelText: l10n.noteTitleLabel,
                    border: InputBorder.none,
                  ),
                  onChanged: (_) {
                    if (!_dirty) {
                      setState(() => _dirty = true);
                    }
                  },
                ),
              ),
              const SizedBox(width: ForgeSpacing.xs),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(l10n.noteEditorSave),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: ForgeSpacing.md),
          child: Row(
            children: <Widget>[
              Flexible(child: _autosaveStatus(context, l10n)),
              const SizedBox(width: ForgeSpacing.sm),
              SegmentedButton<_Mode>(
                segments: <ButtonSegment<_Mode>>[
                  ButtonSegment<_Mode>(
                    value: _Mode.edit,
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(l10n.noteEditTab),
                  ),
                  ButtonSegment<_Mode>(
                    value: _Mode.preview,
                    icon: const Icon(Icons.visibility_outlined),
                    label: Text(l10n.notePreviewTab),
                  ),
                ],
                selected: <_Mode>{_mode},
                onSelectionChanged: (Set<_Mode> value) {
                  // Leaving edit mode flushes the current draft (R-NOTE-005).
                  _flushDraft();
                  setState(() => _mode = value.first);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: ForgeSpacing.xs),
        Expanded(
          child: _mode == _Mode.edit
              ? _buildEditor(context, l10n)
              : MarkdownPreview(
                  body: _body.text,
                  onWikiLink: _openWikiLink,
                  onExternalLink: _openExternalLink,
                  largeDocumentNotice: l10n.noteLargeDocumentNotice,
                  emptyPlaceholder: l10n.notePreviewEmpty,
                ),
        ),
      ],
    );
  }

  Widget _autosaveStatus(BuildContext context, AppLocalizations l10n) {
    final ThemeData theme = Theme.of(context);
    final String label = _dirty
        ? l10n.noteAutosaveDraft
        : l10n.noteAutosaveIdle;
    return Semantics(
      liveRegion: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            _dirty ? Icons.cloud_upload_outlined : Icons.check_circle_outline,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: ForgeSpacing.xxs),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditor(BuildContext context, AppLocalizations l10n) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        for (final MapEntry<ShortcutActivator, MarkdownCommand> entry
            in MarkdownShortcuts.bindings().entries)
          entry.key: () => _applyCommand(entry.value),
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: ForgeSpacing.xs),
            child: MarkdownToolbar(onCommand: _applyCommand),
          ),
          const Divider(height: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(ForgeSpacing.md),
              child: TextField(
                controller: _body,
                focusNode: _bodyFocus,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  labelText: l10n.noteBodyLabel,
                  hintText: l10n.noteBodyHint,
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small stateful dialog for entering a link target. It owns its controller
/// so disposal happens only after the dialog route is fully gone.
final class _LinkUrlDialog extends StatefulWidget {
  const _LinkUrlDialog();

  @override
  State<_LinkUrlDialog> createState() => _LinkUrlDialogState();
}

class _LinkUrlDialogState extends State<_LinkUrlDialog> {
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
      title: Text(l10n.noteFormatLink),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: l10n.noteLinkUrlLabel),
        onSubmitted: (String value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.dialogCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l10n.noteFormatLink),
        ),
      ],
    );
  }
}

final class _NotFound extends StatelessWidget {
  const _NotFound({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ForgeSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: ForgeSpacing.md),
            FilledButton(
              onPressed: () => context.go('/notes'),
              child: Text(context.l10n.notesTitle),
            ),
          ],
        ),
      ),
    );
  }
}
