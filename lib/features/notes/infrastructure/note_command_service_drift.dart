import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notes/application/note_command_service.dart';
import 'package:forge/features/notes/application/note_commands.dart';
import 'package:forge/features/notes/domain/markdown/wiki_link.dart';
import 'package:forge/features/notes/domain/note.dart';
import 'package:forge/features/notes/domain/note_entity_link.dart';
import 'package:forge/features/notes/domain/note_link.dart';
import 'package:forge/features/notes/domain/note_rank.dart';
import 'package:forge/features/notes/infrastructure/note_canonical_request.dart';
import 'package:forge/features/notes/infrastructure/note_draft_repository.dart';
import 'package:forge/features/notes/infrastructure/note_entity_link_repository.dart';
import 'package:forge/features/notes/infrastructure/note_search_projector.dart';
import 'package:forge/features/notes/infrastructure/note_write_repository.dart';
import 'package:forge/features/search/application/search_contracts.dart';

// Private control-flow exceptions raised inside a command body; they roll the
// transaction back and are mapped to a stable [Failure] by the outer wrapper
// (mirrors the task command service).
final class _NotFound implements Exception {
  const _NotFound(this.noteId);
  final String noteId;
}

final class _Validation implements Exception {
  const _Validation(this.code, {this.cause});
  final String code;
  final String? cause;
}

/// Command-bus-backed [NoteCommandService] (R-NOTE-001, R-NOTE-002, R-NOTE-004,
/// R-GEN-005).
///
/// Every mutation is one atomic transaction that writes the note row, refreshes
/// the outgoing `[[wiki-link]]` set, marks the unified search projection dirty
/// (maintained in-commit by the registered [NoteSearchProjector]), and — on a
/// successful body save — removes the note's encrypted draft (R-NOTE-005), all
/// alongside the cross-cutting receipt/activity/outbox/journal write set.
final class DriftNoteCommandService implements NoteCommandService {
  DriftNoteCommandService({
    required this.bus,
    required this.clock,
    required this.idGenerator,
  });

  final ForgeCommandBus bus;
  final Clock clock;
  final IdGenerator idGenerator;

  static const int _payloadVersion = 1;

  int get _now => clock.utcNow().microsecondsSinceEpoch;

  @override
  Future<Result<CommittedCommandResult>> create({
    required CommandId commandId,
    required ProfileId profileId,
    required CreateNoteInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'create',
      'life_area_id': input.lifeAreaId.value,
      'title': input.title,
      'body': input.body,
      'pinned': input.pinned,
      'tag_ids': input.tagIds,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'note.create',
      canonical: canonical,
      body: (TransactionSession session) =>
          _createBody(session, profileId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> update({
    required CommandId commandId,
    required ProfileId profileId,
    required NoteId noteId,
    required UpdateNoteInput input,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'update',
      'note_id': noteId.value,
      if (input.title != null) 'title': input.title,
      if (input.body != null) 'body': input.body,
      if (input.lifeAreaId != null) 'life_area_id': input.lifeAreaId!.value,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'note.update',
      canonical: canonical,
      body: (TransactionSession session) =>
          _updateBody(session, profileId, noteId, input),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> setPinned({
    required CommandId commandId,
    required ProfileId profileId,
    required NoteId noteId,
    required bool pinned,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'set_pinned',
      'note_id': noteId.value,
      'pinned': pinned,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'note.set_pinned',
      canonical: canonical,
      body: (TransactionSession session) =>
          _flagBody(session, profileId, noteId, pinned: pinned),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> setArchived({
    required CommandId commandId,
    required ProfileId profileId,
    required NoteId noteId,
    required bool archived,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'set_archived',
      'note_id': noteId.value,
      'archived': archived,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'note.set_archived',
      canonical: canonical,
      body: (TransactionSession session) =>
          _flagBody(session, profileId, noteId, archived: archived),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> resolveLink({
    required CommandId commandId,
    required ProfileId profileId,
    required String linkId,
    required NoteId chosenNoteId,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'resolve_link',
      'link_id': linkId,
      'chosen_note_id': chosenNoteId.value,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'note.resolve_link',
      canonical: canonical,
      body: (TransactionSession session) =>
          _resolveLinkBody(session, profileId, linkId, chosenNoteId),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> linkEntity({
    required CommandId commandId,
    required ProfileId profileId,
    required NoteId noteId,
    required String targetType,
    required String targetId,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'link_entity',
      'note_id': noteId.value,
      'target_type': targetType,
      'target_id': targetId,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'note.link_entity',
      canonical: canonical,
      body: (TransactionSession session) =>
          _linkEntityBody(session, profileId, noteId, targetType, targetId),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> unlinkEntity({
    required CommandId commandId,
    required ProfileId profileId,
    required NoteId noteId,
    required String targetType,
    required String targetId,
  }) {
    final Map<String, Object?> canonical = <String, Object?>{
      'op': 'unlink_entity',
      'note_id': noteId.value,
      'target_type': targetType,
      'target_id': targetId,
    };
    return _run(
      profileId: profileId,
      commandId: commandId,
      commandType: 'note.unlink_entity',
      canonical: canonical,
      body: (TransactionSession session) =>
          _unlinkEntityBody(session, profileId, noteId, targetType, targetId),
    );
  }

  // ---- command bodies -----------------------------------------------------

  Future<SemanticWrite> _createBody(
    TransactionSession session,
    ProfileId profileId,
    CreateNoteInput input,
  ) async {
    final NoteWriteRepository repo = session.repositories
        .resolve<NoteWriteRepository>();
    final int now = _now;
    final NoteRank rank = NoteRank.append(await repo.lastRank(profileId.value));
    final String noteId = idGenerator.uuidV7();
    final String normalizedTitle = normalizeNoteTitle(input.title);

    final Note note = _guardConstruct(
      () => Note(
        id: NoteId(noteId),
        profileId: profileId,
        lifeAreaId: input.lifeAreaId,
        title: input.title,
        body: input.body,
        contentHash: _hash(input.title, input.body),
        pinned: input.pinned,
        rank: rank,
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
    );

    await repo.insert(note, normalizedTitle: normalizedTitle);
    for (final String tagId in input.tagIds) {
      await repo.attachTag(
        profileId: profileId.value,
        noteId: noteId,
        tagId: tagId,
        nowUtc: now,
      );
    }
    await _maintainLinks(repo, profileId, noteId, input.body, now);
    // The new note is now a live title match: re-resolve inbound links that
    // referenced this title (binding a previously missing reference, or making
    // a formerly single match ambiguous) — same commit as the write.
    await repo.reResolveByNormalizedTarget(profileId.value, normalizedTitle);

    final int epoch = await repo.currentEpoch(profileId.value);
    return SemanticWrite(
      resultCode: 'created',
      payloadVersion: _payloadVersion,
      resultPayload: '{"id":"$noteId"}',
      activity: <ActivityDraft>[_activity('created', noteId)],
      dirtyProjections: _dirty(noteId),
      outboxGroup: _group(<OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: NoteSearchProjector.kind,
          entityId: noteId,
          opKind: 'insert',
          payload: _notePayload(note),
        ),
      ], epoch),
    );
  }

  Future<SemanticWrite> _updateBody(
    TransactionSession session,
    ProfileId profileId,
    NoteId noteId,
    UpdateNoteInput input,
  ) async {
    final NoteWriteRepository repo = session.repositories
        .resolve<NoteWriteRepository>();
    final Note? current = await repo.find(profileId.value, noteId.value);
    if (current == null) {
      throw _NotFound(noteId.value);
    }
    if (current.isDeleted) {
      throw const _Validation('note.deleted');
    }
    if (input.isEmpty) {
      return _noop(noteId.value);
    }

    final int now = _now;
    final String newTitle = input.title ?? current.title;
    final String newBody = input.body ?? current.body;
    final Note updated = _guardConstruct(
      () => current.copyWith(
        title: input.title,
        body: input.body,
        lifeAreaId: input.lifeAreaId,
        contentHash: _hash(newTitle, newBody),
        revision: current.revision + 1,
        updatedAtUtc: now,
      ),
    );
    final String oldNormalizedTitle = normalizeNoteTitle(current.title);
    final String newNormalizedTitle = normalizeNoteTitle(newTitle);
    await repo.update(updated, normalizedTitle: newNormalizedTitle);

    // The body may have changed the outgoing links; refresh them in-commit.
    if (input.body != null) {
      await _maintainLinks(repo, profileId, noteId.value, newBody, now);
    }

    // A rename repairs inbound link resolution deterministically: links that
    // referenced the OLD title no longer match (drop to unresolved), and links
    // that referenced the NEW title now bind (or become ambiguous). Both sets
    // are recomputed in the same commit as the write (R-NOTE-003).
    if (newNormalizedTitle != oldNormalizedTitle) {
      await repo.reResolveByNormalizedTarget(
        profileId.value,
        oldNormalizedTitle,
      );
      await repo.reResolveByNormalizedTarget(
        profileId.value,
        newNormalizedTitle,
      );
    }

    // A successful save removes any pending draft for this note (R-NOTE-005).
    await session.repositories.resolve<NoteDraftWriteRepository>().remove(
      profileId: profileId.value,
      noteId: noteId.value,
    );

    return SemanticWrite(
      resultCode: 'updated',
      payloadVersion: _payloadVersion,
      resultPayload: '{"id":"${noteId.value}"}',
      activity: <ActivityDraft>[_activity('updated', noteId.value)],
      dirtyProjections: _dirty(noteId.value),
      outboxGroup: _group(<OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: NoteSearchProjector.kind,
          entityId: noteId.value,
          opKind: 'patch',
          baseRowVersion: current.revision,
          payload: _notePayload(updated),
        ),
      ], await repo.currentEpoch(profileId.value)),
    );
  }

  Future<SemanticWrite> _flagBody(
    TransactionSession session,
    ProfileId profileId,
    NoteId noteId, {
    bool? pinned,
    bool? archived,
  }) async {
    final NoteWriteRepository repo = session.repositories
        .resolve<NoteWriteRepository>();
    final Note? current = await repo.find(profileId.value, noteId.value);
    if (current == null) {
      throw _NotFound(noteId.value);
    }
    if (current.isDeleted) {
      throw const _Validation('note.deleted');
    }

    final int now = _now;
    final bool nextPinned = pinned ?? current.pinned;
    final int? nextArchived = archived == null
        ? current.archivedAtUtc
        : (archived ? (current.archivedAtUtc ?? now) : null);

    // Idempotent no-op when nothing changes.
    if (nextPinned == current.pinned &&
        (nextArchived == null) == (current.archivedAtUtc == null)) {
      return _noop(noteId.value);
    }

    final Note updated = current.copyWith(
      pinned: nextPinned,
      archivedAtUtc: archived == null ? Note.unchanged : nextArchived,
      revision: current.revision + 1,
      updatedAtUtc: now,
    );
    await repo.update(
      updated,
      normalizedTitle: normalizeNoteTitle(updated.title),
    );

    final String changed = pinned != null ? 'pinned' : 'archived_at_utc';
    return SemanticWrite(
      resultCode: pinned != null
          ? (nextPinned ? 'pinned' : 'unpinned')
          : (archived! ? 'archived' : 'unarchived'),
      payloadVersion: _payloadVersion,
      resultPayload: '{"id":"${noteId.value}"}',
      activity: <ActivityDraft>[
        _activity(
          pinned != null ? 'pin_changed' : 'archive_changed',
          noteId.value,
        ),
      ],
      dirtyProjections: _dirty(noteId.value),
      outboxGroup: _group(<OutboxOperationDraft>[
        OutboxOperationDraft(
          operationId: idGenerator.uuidV7(),
          entityType: NoteSearchProjector.kind,
          entityId: noteId.value,
          opKind: 'patch',
          changedFields: changed,
          baseRowVersion: current.revision,
          payload: _notePayload(updated),
        ),
      ], await repo.currentEpoch(profileId.value)),
    );
  }

  /// Parses `[[wiki-links]]` from [body], resolves each by single normalized
  /// title match, and replaces the note's outgoing link set (R-NOTE-003/004).
  Future<void> _maintainLinks(
    NoteWriteRepository repo,
    ProfileId profileId,
    String noteId,
    String body,
    int nowUtc,
  ) async {
    final List<WikiLinkRef> refs = WikiLink.extract(body);
    final List<NoteLink> links = <NoteLink>[];
    for (final WikiLinkRef ref in refs) {
      final String normalized = normalizeNoteTitle(ref.target);
      final List<String> matches = await repo.idsByNormalizedTitle(
        profileId.value,
        normalized,
      );
      // A note never links to itself. Exactly one live match binds; zero
      // matches stay unresolved; multiple matches are ambiguous and MUST be
      // resolved by explicit selection rather than a silent pick (R-NOTE-003).
      final List<String> candidates = matches
          .where((String id) => id != noteId)
          .toList(growable: false);
      final WikiLinkResolution resolution = WikiLinkResolution.classify(
        candidates,
      );
      final String? target = resolution == WikiLinkResolution.resolved
          ? candidates.single
          : null;
      links.add(
        NoteLink(
          id: idGenerator.uuidV7(),
          profileId: profileId,
          sourceNoteId: NoteId(noteId),
          targetTitle: ref.target,
          normalizedTarget: normalized,
          label: ref.label,
          sourceStart: ref.start,
          sourceEnd: ref.end,
          targetNoteId: target == null ? null : NoteId(target),
          resolution: resolution,
        ),
      );
    }
    await repo.replaceLinks(
      profileId: profileId.value,
      sourceNoteId: noteId,
      links: links,
      nowUtc: nowUtc,
    );
  }

  Future<SemanticWrite> _resolveLinkBody(
    TransactionSession session,
    ProfileId profileId,
    String linkId,
    NoteId chosenNoteId,
  ) async {
    final NoteWriteRepository repo = session.repositories
        .resolve<NoteWriteRepository>();
    final NoteLink? link = await repo.findLink(profileId.value, linkId);
    if (link == null) {
      throw const _Validation('note.link_not_found');
    }
    // The chosen note must be a live candidate for this link's target title —
    // never a silent or arbitrary pick (R-NOTE-003). This also rejects a choice
    // that no longer matches (e.g. the candidate was renamed since the prompt).
    final List<String> candidates = await repo.idsByNormalizedTitle(
      profileId.value,
      link.normalizedTarget,
    );
    final bool isCandidate =
        chosenNoteId.value != link.sourceNoteId.value &&
        candidates.contains(chosenNoteId.value);
    if (!isCandidate) {
      throw const _Validation('note.link_choice_invalid');
    }
    if (link.targetNoteId?.value == chosenNoteId.value) {
      return _noop(link.sourceNoteId.value); // Already bound to that note.
    }
    await repo.bindLinkTarget(profileId.value, linkId, chosenNoteId.value);
    return SemanticWrite(
      resultCode: 'link_resolved',
      payloadVersion: _payloadVersion,
      resultPayload:
          '{"link_id":"$linkId","target_note_id":"${chosenNoteId.value}"}',
      activity: <ActivityDraft>[
        _activity('link_resolved', link.sourceNoteId.value),
      ],
    );
  }

  Future<SemanticWrite> _linkEntityBody(
    TransactionSession session,
    ProfileId profileId,
    NoteId noteId,
    String targetType,
    String targetId,
  ) async {
    final NoteEntityLinkRepository repo = session.repositories
        .resolve<NoteEntityLinkRepository>();
    final NoteEntityLinkOutcome outcome = await repo.link(
      id: idGenerator.uuidV7(),
      profileId: profileId.value,
      noteId: noteId.value,
      targetType: targetType,
      targetId: targetId,
      rank: NoteRank.append(null).value,
      nowUtc: _now,
    );
    switch (outcome) {
      case NoteEntityLinkOutcome.noteMissing:
        throw _NotFound(noteId.value);
      case NoteEntityLinkOutcome.targetTypeUnknown:
        throw const _Validation('note.entity_target_type_unknown');
      case NoteEntityLinkOutcome.targetTypeUnavailable:
        throw const _Validation('note.entity_target_type_unavailable');
      case NoteEntityLinkOutcome.targetMissing:
        // Not found under this profile — includes cross-profile ids (R-GEN-002).
        throw const _Validation('note.entity_target_not_found');
      case NoteEntityLinkOutcome.alreadyLinked:
        return _noop(noteId.value);
      case NoteEntityLinkOutcome.linked:
        return SemanticWrite(
          resultCode: 'entity_linked',
          payloadVersion: _payloadVersion,
          resultPayload:
              '{"note_id":"${noteId.value}","to_type":"$targetType",'
              '"to_id":"$targetId"}',
          activity: <ActivityDraft>[_activity('entity_linked', noteId.value)],
        );
    }
  }

  Future<SemanticWrite> _unlinkEntityBody(
    TransactionSession session,
    ProfileId profileId,
    NoteId noteId,
    String targetType,
    String targetId,
  ) async {
    final NoteEntityLinkRepository repo = session.repositories
        .resolve<NoteEntityLinkRepository>();
    final int removed = await repo.unlink(
      profileId: profileId.value,
      noteId: noteId.value,
      targetType: targetType,
      targetId: targetId,
    );
    if (removed == 0) {
      return _noop(noteId.value);
    }
    return SemanticWrite(
      resultCode: 'entity_unlinked',
      payloadVersion: _payloadVersion,
      resultPayload:
          '{"note_id":"${noteId.value}","to_type":"$targetType",'
          '"to_id":"$targetId"}',
      activity: <ActivityDraft>[_activity('entity_unlinked', noteId.value)],
    );
  }

  // ---- helpers ------------------------------------------------------------

  Future<Result<CommittedCommandResult>> _run({
    required ProfileId profileId,
    required CommandId commandId,
    required String commandType,
    required Map<String, Object?> canonical,
    required CommandBody body,
  }) async {
    final String payload = NoteCanonicalRequest.encode(canonical);
    final DurableCommand command = DurableCommand(
      profileId: profileId,
      commandId: commandId,
      commandType: commandType,
      schemaVersion: _payloadVersion,
      requestHash: NoteCanonicalRequest.stableHash(payload),
      canonicalPayload: payload,
    );
    try {
      return await bus.execute(command, body);
    } on _NotFound catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: 'note.not_found',
          safeMessageKey: 'error.note.not_found',
          retryable: false,
          redactedCause: e.noteId,
        ),
      );
    } on _Validation catch (e) {
      return Failed<CommittedCommandResult>(
        Failure(
          kind: FailureKind.validation,
          code: e.code,
          safeMessageKey: 'error.note.invalid',
          retryable: false,
          redactedCause: e.cause,
        ),
      );
    }
  }

  Note _guardConstruct(Note Function() build) {
    try {
      return build();
    } on FormatException catch (e) {
      throw _Validation('note.invalid_field', cause: e.message);
    }
  }

  SemanticWrite _noop(String noteId) => SemanticWrite(
    resultCode: 'noop',
    payloadVersion: _payloadVersion,
    resultPayload: '{"id":"$noteId"}',
  );

  ActivityDraft _activity(String eventType, String noteId) => ActivityDraft(
    id: idGenerator.uuidV7(),
    eventType: eventType,
    entityType: NoteSearchProjector.kind,
    entityId: noteId,
    payloadVersion: _payloadVersion,
  );

  List<DirtyProjectionDraft> _dirty(String noteId) => <DirtyProjectionDraft>[
    DirtyProjectionDraft(
      projection: SearchDirtyKey.projection,
      projectionKey: SearchDirtyKey.encode(NoteSearchProjector.kind, noteId),
    ),
  ];

  OutboxGroupDraft? _group(List<OutboxOperationDraft> operations, int epoch) {
    if (operations.isEmpty) {
      return null;
    }
    return OutboxGroupDraft(
      groupId: idGenerator.uuidV7(),
      snapshotEpoch: epoch,
      operations: operations,
    );
  }

  String _hash(String title, String body) =>
      NoteCanonicalRequest.stableHash('$title\n$body');

  String _notePayload(Note note) =>
      NoteCanonicalRequest.encode(<String, Object?>{
        'id': note.id.value,
        'life_area_id': note.lifeAreaId.value,
        'title': note.title,
        'body': note.body,
        'content_hash': note.contentHash,
        'pinned': note.pinned,
        'archived_at_utc': note.archivedAtUtc,
        'rank': note.rank.value,
        'revision': note.revision,
      });
}
