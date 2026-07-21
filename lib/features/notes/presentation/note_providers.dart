import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/deletion/deletion_service.dart';
import 'package:forge/app/infrastructure/database/deletion/purge_preview.dart';
import 'package:forge/app/routing/uri_policy.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notes/application/note_command_service.dart';
import 'package:forge/features/notes/application/note_commands.dart';
import 'package:forge/features/notes/application/note_draft_journal.dart';
import 'package:forge/features/notes/domain/note.dart';
import 'package:forge/features/notes/domain/note_draft.dart';
import 'package:forge/features/notes/domain/note_repository.dart';

// ---------------------------------------------------------------------------
// Composition seams. Defaults keep the running app honest before the encrypted
// runtime is wired; the composition root and tests override them. The notes
// feature owns its own seams and depends only on its domain/application
// contracts, never another feature's infrastructure (design.md §4).
// ---------------------------------------------------------------------------

/// The active local profile, or null when no generation is open yet.
final Provider<ProfileId?> notesProfileProvider = Provider<ProfileId?>(
  (Ref ref) => null,
);

/// The notes read model (domain contract). Null until wired.
final Provider<NoteRepository?> notesRepositoryProvider =
    Provider<NoteRepository?>((Ref ref) => null);

/// The durable note command contract. Null until wired.
final Provider<NoteCommandService?> notesCommandServiceProvider =
    Provider<NoteCommandService?>((Ref ref) => null);

/// The encrypted durable draft journal (R-NOTE-005). Null until wired.
final Provider<NoteDraftJournal?> notesDraftJournalProvider =
    Provider<NoteDraftJournal?>((Ref ref) => null);

/// The soft-delete / restore kernel used by the list Trash actions. Null until
/// wired.
final Provider<DeletionService?> notesDeletionServiceProvider =
    Provider<DeletionService?>((Ref ref) => null);

/// Trusted clock.
final Provider<Clock> notesClockProvider = Provider<Clock>(
  (Ref ref) => const _SystemUtcClock(),
);

/// Produces a fresh unique [CommandId] per durable command (R-GEN-005).
final Provider<CommandId Function()> notesCommandIdFactoryProvider =
    Provider<CommandId Function()>((Ref ref) => _defaultCommandId);

/// The centralized URI policy that gates outbound link opening (R-SEC-005).
final Provider<UriPolicy> notesUriPolicyProvider = Provider<UriPolicy>(
  (Ref ref) => UriPolicy(),
);

/// The OS handoff for an allowlisted, user-initiated external link. Default
/// refuses (returns false); the platform composition overrides it with a real
/// launcher and tests override it to capture the attempt. Keeping this a seam
/// means the notes feature never performs arbitrary URI opening itself.
final Provider<Future<bool> Function(Uri uri)> notesLinkLauncherProvider =
    Provider<Future<bool> Function(Uri uri)>(
      (Ref ref) =>
          (Uri uri) async => false,
    );

/// The debounce window before an idle edit flushes to the draft journal
/// (R-NOTE-005). Overridable so tests can pump deterministically.
final Provider<Duration> notesAutosaveDebounceProvider = Provider<Duration>(
  (Ref ref) => const Duration(milliseconds: 800),
);

/// A selectable Life Area for the new-note flow. Names are decorative; the id
/// is the identifier (ux-design §5).
final class NoteAreaOption {
  const NoteAreaOption({required this.id, required this.name});
  final LifeAreaId id;
  final String name;
}

/// The Life Areas offered by the new-note flow. Default empty; overridden by
/// the app.
final Provider<List<NoteAreaOption>> notesAreaOptionsProvider =
    Provider<List<NoteAreaOption>>((Ref ref) => const <NoteAreaOption>[]);

/// The default Life Area a newly created note inherits (R-GEN-002). Null when
/// unavailable, in which case create is unavailable.
final Provider<LifeAreaId?> notesDefaultAreaProvider = Provider<LifeAreaId?>((
  Ref ref,
) {
  final List<NoteAreaOption> options = ref.watch(notesAreaOptionsProvider);
  return options.isEmpty ? null : options.first.id;
});

/// Whether the notes read stack is wired at all.
final Provider<bool> notesConfiguredProvider = Provider<bool>((Ref ref) {
  return ref.watch(notesProfileProvider) != null &&
      ref.watch(notesRepositoryProvider) != null;
});

// ---------------------------------------------------------------------------
// List view + query.
// ---------------------------------------------------------------------------

/// The currently selected notes view (R-NOTE-002).
final class NoteViewController extends Notifier<NoteViewKind> {
  @override
  NoteViewKind build() => NoteViewKind.all;

  void set(NoteViewKind view) {
    if (state != view) {
      state = view;
    }
  }
}

final NotifierProvider<NoteViewController, NoteViewKind> noteViewProvider =
    NotifierProvider<NoteViewController, NoteViewKind>(NoteViewController.new);

/// Loads the notes for the current view (R-NOTE-002). Reads run against the
/// active local generation, so the list is always available offline
/// (R-GEN-001).
final class NoteListController extends AsyncNotifier<List<Note>> {
  @override
  Future<List<Note>> build() async {
    final ProfileId? profile = ref.watch(notesProfileProvider);
    final NoteRepository? repo = ref.watch(notesRepositoryProvider);
    final NoteViewKind view = ref.watch(noteViewProvider);
    if (profile == null || repo == null) {
      return const <Note>[];
    }
    return repo.view(profile, view);
  }

  void reload() => ref.invalidateSelf();
}

final AsyncNotifierProvider<NoteListController, List<Note>> noteListProvider =
    AsyncNotifierProvider<NoteListController, List<Note>>(
      NoteListController.new,
    );

/// Loads a single note by id. Auto-disposes when the detail route is popped.
final noteDetailProvider = FutureProvider.autoDispose.family<Note?, String>((
  Ref ref,
  String noteId,
) async {
  final ProfileId? profile = ref.watch(notesProfileProvider);
  final NoteRepository? repo = ref.watch(notesRepositoryProvider);
  if (profile == null || repo == null) {
    return null;
  }
  return repo.findById(profile, NoteId(noteId));
});

/// Loads the pending encrypted draft for a note, if any (R-NOTE-005). Used by
/// the editor to offer crash/restart recovery on open.
final noteDraftProvider = FutureProvider.autoDispose.family<NoteDraft?, String>(
  (Ref ref, String noteId) async {
    final ProfileId? profile = ref.watch(notesProfileProvider);
    final NoteDraftJournal? journal = ref.watch(notesDraftJournalProvider);
    if (profile == null || journal == null) {
      return null;
    }
    return journal.load(profileId: profile, noteId: NoteId(noteId));
  },
);

// ---------------------------------------------------------------------------
// Mutating actions (create / pin / archive / soft-delete) with Undo feedback.
// ---------------------------------------------------------------------------

const Failure _unavailableFailure = Failure(
  kind: FailureKind.unavailableCapability,
  code: 'notes.unavailable',
  safeMessageKey: 'error.capability',
  retryable: false,
);

/// A reversible action the UI can offer as immediate Undo (R-GEN-003).
final class NoteUndo {
  const NoteUndo({required this.messageCode, required this.undo});
  final String messageCode;
  final Future<Result<CommittedCommandResult>> Function() undo;
}

/// Transient feedback from the most recent list action.
sealed class NoteFeedback {
  const NoteFeedback();
}

final class NoteFeedbackNone extends NoteFeedback {
  const NoteFeedbackNone();
}

final class NoteFeedbackUndo extends NoteFeedback {
  const NoteFeedbackUndo(this.offer);
  final NoteUndo offer;
}

final class NoteFeedbackError extends NoteFeedback {
  const NoteFeedbackError(this.failure);
  final Failure failure;
}

/// Orchestrates note list mutations over the durable command contracts. Holds
/// no business rules; maps a UI intent to a command, awaits the committed
/// result and refreshes the list.
final class NoteActionsController extends Notifier<NoteFeedback> {
  @override
  NoteFeedback build() => const NoteFeedbackNone();

  void dismiss() => state = const NoteFeedbackNone();

  CommandId _id() => ref.read(notesCommandIdFactoryProvider)();
  ProfileId? get _profile => ref.read(notesProfileProvider);
  NoteCommandService? get _commands => ref.read(notesCommandServiceProvider);
  DeletionService? get _deletion => ref.read(notesDeletionServiceProvider);

  void _refresh() => ref.invalidate(noteListProvider);

  /// Creates a title-only note and returns its generated id, or null on
  /// failure. The editor opens on the returned id so the body is edited over
  /// the canonical note with exact-base draft journaling (R-NOTE-005).
  Future<String?> create({required String title}) async {
    final NoteCommandService? commands = _commands;
    final ProfileId? profile = _profile;
    final LifeAreaId? area = ref.read(notesDefaultAreaProvider);
    if (commands == null || profile == null || area == null) {
      state = const NoteFeedbackError(_unavailableFailure);
      return null;
    }
    final Result<CommittedCommandResult> result = await commands.create(
      commandId: _id(),
      profileId: profile,
      input: CreateNoteInput(lifeAreaId: area, title: title),
    );
    switch (result) {
      case Success<CommittedCommandResult>(
        value: final CommittedCommandResult r,
      ):
        _refresh();
        return _idFromPayload(r.resultPayload);
      case Failed<CommittedCommandResult>(failure: final Failure f):
        state = NoteFeedbackError(f);
        return null;
    }
  }

  Future<Result<CommittedCommandResult>> setPinned(
    String noteId, {
    required bool pinned,
  }) async {
    final NoteCommandService? commands = _commands;
    final ProfileId? profile = _profile;
    if (commands == null || profile == null) {
      state = const NoteFeedbackError(_unavailableFailure);
      return const Failed<CommittedCommandResult>(_unavailableFailure);
    }
    final Result<CommittedCommandResult> result = await commands.setPinned(
      commandId: _id(),
      profileId: profile,
      noteId: NoteId(noteId),
      pinned: pinned,
    );
    _afterMutation(result);
    return result;
  }

  Future<Result<CommittedCommandResult>> setArchived(
    String noteId, {
    required bool archived,
  }) async {
    final NoteCommandService? commands = _commands;
    final ProfileId? profile = _profile;
    if (commands == null || profile == null) {
      state = const NoteFeedbackError(_unavailableFailure);
      return const Failed<CommittedCommandResult>(_unavailableFailure);
    }
    final Result<CommittedCommandResult> result = await commands.setArchived(
      commandId: _id(),
      profileId: profile,
      noteId: NoteId(noteId),
      archived: archived,
    );
    _afterMutation(result);
    return result;
  }

  /// Soft-deletes a note through the shared deletion kernel and offers Undo
  /// (R-GEN-003).
  Future<Result<CommittedCommandResult>> softDelete(String noteId) async {
    final DeletionService? deletion = _deletion;
    final ProfileId? profile = _profile;
    if (deletion == null || profile == null) {
      state = const NoteFeedbackError(_unavailableFailure);
      return const Failed<CommittedCommandResult>(_unavailableFailure);
    }
    final EntityRef entity = EntityRef(entityType: 'note', entityId: noteId);
    final Result<CommittedCommandResult> result = await deletion.softDelete(
      command: _deletionCommand(profile, 'note.soft_delete', noteId),
      ref: entity,
    );
    _afterMutation(
      result,
      undo: NoteUndo(
        messageCode: 'deleted',
        undo: () => _restore(profile, entity),
      ),
    );
    return result;
  }

  Future<Result<CommittedCommandResult>> restore(String noteId) async {
    final ProfileId? profile = _profile;
    if (_deletion == null || profile == null) {
      state = const NoteFeedbackError(_unavailableFailure);
      return const Failed<CommittedCommandResult>(_unavailableFailure);
    }
    return _restore(profile, EntityRef(entityType: 'note', entityId: noteId));
  }

  Future<Result<CommittedCommandResult>> _restore(
    ProfileId profile,
    EntityRef entity,
  ) async {
    final Result<CommittedCommandResult> result = await _deletion!.restore(
      command: _deletionCommand(profile, 'note.restore', entity.entityId),
      ref: entity,
    );
    if (result is Success<CommittedCommandResult>) {
      _refresh();
    }
    return result;
  }

  void _afterMutation(Result<CommittedCommandResult> result, {NoteUndo? undo}) {
    switch (result) {
      case Success<CommittedCommandResult>():
        _refresh();
        state = undo == null
            ? const NoteFeedbackNone()
            : NoteFeedbackUndo(undo);
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        state = NoteFeedbackError(failure);
    }
  }

  DurableCommand _deletionCommand(ProfileId profile, String type, String id) {
    final String payload = '{"op":"$type","id":"$id"}';
    return DurableCommand(
      profileId: profile,
      commandId: _id(),
      commandType: type,
      schemaVersion: 1,
      requestHash: _stableHash(payload),
      canonicalPayload: payload,
    );
  }
}

final NotifierProvider<NoteActionsController, NoteFeedback>
noteActionsProvider = NotifierProvider<NoteActionsController, NoteFeedback>(
  NoteActionsController.new,
);

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

String? _idFromPayload(String? payload) {
  if (payload == null) {
    return null;
  }
  final RegExp idPattern = RegExp(r'"id"\s*:\s*"([^"]+)"');
  return idPattern.firstMatch(payload)?.group(1);
}

String _stableHash(String input) {
  const int prime = 0x100000001b3;
  int hash = 0xcbf29ce484222325;
  for (final int unit in input.codeUnits) {
    hash = (hash ^ unit) * prime;
    hash &= 0xffffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

final Random _random = Random();

CommandId _defaultCommandId() {
  final int micros = DateTime.now().toUtc().microsecondsSinceEpoch;
  final String salt = _random.nextInt(1 << 32).toRadixString(16);
  return CommandId('cmd-$micros-$salt');
}

final class _SystemUtcClock implements Clock {
  const _SystemUtcClock();

  @override
  DateTime utcNow() => DateTime.now().toUtc();

  @override
  String timezoneId() => 'UTC';
}
