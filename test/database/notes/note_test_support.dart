import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/deletion/deletion_maintenance.dart';
import 'package:forge/app/infrastructure/database/deletion/deletion_service.dart';
import 'package:forge/app/infrastructure/database/deletion/purge_preview.dart';
import 'package:forge/app/infrastructure/database/deletion/trashable_entity.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notes/application/note_commands.dart';
import 'package:forge/features/notes/application/note_draft_cipher.dart';
import 'package:forge/features/notes/application/note_draft_journal.dart';
import 'package:forge/features/notes/infrastructure/note_command_service_drift.dart';
import 'package:forge/features/notes/infrastructure/note_draft_journal_drift.dart';
import 'package:forge/features/notes/infrastructure/note_link_deletion_maintenance.dart';
import 'package:forge/features/notes/infrastructure/note_read_repository.dart';
import 'package:forge/features/notes/infrastructure/note_repository_factories.dart';
import 'package:forge/features/notes/infrastructure/note_search_projector.dart';
import 'package:forge/features/search/application/search_projector.dart';
import 'package:forge/features/search/infrastructure/search_projection_registry.dart';
import 'package:forge/features/search/infrastructure/search_read_repository.dart';
import 'package:forge/features/search/infrastructure/search_repository_factories.dart';
import 'package:forge/features/tasks/infrastructure/task_search_projector.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';
import '../schema/schema_test_database.dart';
import '../tasks/task_test_support.dart';

/// A deterministic, reversible test cipher for the draft journal.
///
/// It is intentionally NOT plaintext: the sealed form is a tagged, reversed
/// base64 payload, so tests can prove the stored draft body is never legible
/// while still round-tripping through [open]. Production supplies a real AEAD
/// over the KeyVault-released profile key.
final class FakeDraftCipher implements NoteDraftCipher {
  const FakeDraftCipher();

  static const String _tag = 'enc1:';

  @override
  String seal(String plaintext) {
    final String b64 = base64.encode(utf8.encode(plaintext));
    return '$_tag${String.fromCharCodes(b64.codeUnits.reversed)}';
  }

  @override
  String open(String sealed) {
    if (!sealed.startsWith(_tag)) {
      throw const FormatException('Not a sealed draft envelope.');
    }
    final String reversed = sealed.substring(_tag.length);
    final String b64 = String.fromCharCodes(reversed.codeUnits.reversed);
    return utf8.decode(base64.decode(b64));
  }
}

/// Wiring for real Drift-backed note tests: the note command service with the
/// in-transaction search coordinator (task + note projectors), the note read
/// model, the unified search read model, the encrypted draft journal, and the
/// deletion kernel with `note` registered as trashable.
final class NoteHarness {
  NoteHarness._(
    this.db,
    this.profileId,
    this.lifeAreaId,
    this.clock,
    this.ids,
    this.notes,
    this.reads,
    this.search,
    this.journal,
    this.deletion,
    this.registry,
  );

  static Future<NoteHarness> open({
    DateTime? initialUtc,
    String areaId = 'area-1',
  }) async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    await insertLifeArea(db, profileId, id: areaId);
    final FakeClock clock = FakeClock(
      initialUtc: initialUtc ?? DateTime.utc(2024, 6, 1, 12),
    );
    final FakeIdGenerator ids = FakeIdGenerator.sequential();
    final SearchProjectionRegistry registry = SearchProjectionRegistry(
      const <SearchProjector>[TaskSearchProjector(), NoteSearchProjector()],
    );
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: <Type, RepositoryFactory>{
        ...noteRepositoryFactories,
        ...searchRepositoryFactories,
      },
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
      searchCoordinator: registry,
    );
    final DriftNoteCommandService service = DriftNoteCommandService(
      bus: bus,
      clock: clock,
      idGenerator: ids,
    );
    final DriftNoteDraftJournal journal = DriftNoteDraftJournal(
      unitOfWork: unitOfWork,
      cipher: const FakeDraftCipher(),
      clock: clock,
    );
    final DeletionService deletion = DeletionService(
      bus: bus,
      registry: TrashRegistry(<TrashableEntity>[
        TrashableEntity(
          entityType: noteTrashableEntityType,
          tableName: 'notes',
        ),
      ]),
      clock: clock,
      idGenerator: ids,
      // Inbound wiki-link resolution is repaired in the same commit as the
      // note trash/restore/purge (R-NOTE-003).
      maintenanceHooks: const <String, DeletionMaintenanceHook>{
        noteTrashableEntityType: NoteLinkDeletionMaintenance(),
      },
    );
    return NoteHarness._(
      db,
      ProfileId(profileId),
      LifeAreaId(areaId),
      clock,
      ids,
      service,
      NoteReadRepository(db),
      SearchReadRepository(db),
      journal,
      deletion,
      registry,
    );
  }

  final ForgeSchemaDatabase db;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final FakeClock clock;
  final FakeIdGenerator ids;
  final DriftNoteCommandService notes;
  final NoteReadRepository reads;
  final SearchReadRepository search;
  final NoteDraftJournal journal;
  final DeletionService deletion;
  final SearchProjectionRegistry registry;

  int _cmd = 0;
  CommandId nextCommandId([String? seed]) =>
      CommandId('cmd-${seed ?? (_cmd++).toString()}');

  Future<void> close() => db.close();

  Future<int> scalar(
    String sql, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final List<QueryRow> rows = await db
        .customSelect(
          sql,
          variables: <Variable<Object>>[
            for (final Object? a in args) Variable<Object>(a as Object),
          ],
        )
        .get();
    return rows.single.data.values.first as int;
  }

  Future<Map<String, Object?>?> firstRow(
    String sql, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final List<QueryRow> rows = await db
        .customSelect(
          sql,
          variables: <Variable<Object>>[
            for (final Object? a in args) Variable<Object>(a as Object),
          ],
        )
        .get();
    return rows.isEmpty ? null : rows.first.data;
  }

  /// Creates a note and returns its id.
  Future<String> createNote({
    String title = 'A note',
    String body = '',
    bool pinned = false,
    List<String> tagIds = const <String>[],
    String? seed,
  }) async {
    final Result<CommittedCommandResult> result = await notes.create(
      commandId: nextCommandId(seed),
      profileId: profileId,
      input: CreateNoteInput(
        lifeAreaId: lifeAreaId,
        title: title,
        body: body,
        pinned: pinned,
        tagIds: tagIds,
      ),
    );
    final CommittedCommandResult r =
        (result as Success<CommittedCommandResult>).value;
    return (jsonDecode(r.resultPayload!) as Map<String, Object?>)['id']
        as String;
  }

  Future<Result<CommittedCommandResult>> softDelete(String noteId) {
    return deletion.softDelete(
      command: DurableCommand(
        profileId: profileId,
        commandId: nextCommandId(),
        commandType: 'note.delete',
        schemaVersion: 1,
        requestHash: 'h-del-$noteId',
        canonicalPayload: '{"note_id":"$noteId"}',
      ),
      ref: EntityRef(entityType: noteTrashableEntityType, entityId: noteId),
    );
  }

  Future<Result<CommittedCommandResult>> restore(String noteId) {
    return deletion.restore(
      command: DurableCommand(
        profileId: profileId,
        commandId: nextCommandId(),
        commandType: 'note.restore',
        schemaVersion: 1,
        requestHash: 'h-res-$noteId',
        canonicalPayload: '{"note_id":"$noteId"}',
      ),
      ref: EntityRef(entityType: noteTrashableEntityType, entityId: noteId),
    );
  }

  /// Renames a note (title-only update) and returns the command result.
  Future<Result<CommittedCommandResult>> rename(
    String noteId,
    String title, {
    String? seed,
  }) {
    return notes.update(
      commandId: nextCommandId(seed),
      profileId: profileId,
      noteId: NoteId(noteId),
      input: UpdateNoteInput(title: title),
    );
  }

  /// Edits a note body and returns the command result.
  Future<Result<CommittedCommandResult>> editBody(
    String noteId,
    String body, {
    String? seed,
  }) {
    return notes.update(
      commandId: nextCommandId(seed),
      profileId: profileId,
      noteId: NoteId(noteId),
      input: UpdateNoteInput(body: body),
    );
  }

  Future<Result<CommittedCommandResult>> resolveLink(
    String linkId,
    String chosenNoteId, {
    String? seed,
  }) {
    return notes.resolveLink(
      commandId: nextCommandId(seed),
      profileId: profileId,
      linkId: linkId,
      chosenNoteId: NoteId(chosenNoteId),
    );
  }

  Future<Result<CommittedCommandResult>> linkEntity(
    String noteId,
    String targetType,
    String targetId, {
    String? seed,
  }) {
    return notes.linkEntity(
      commandId: nextCommandId(seed),
      profileId: profileId,
      noteId: NoteId(noteId),
      targetType: targetType,
      targetId: targetId,
    );
  }

  Future<Result<CommittedCommandResult>> unlinkEntity(
    String noteId,
    String targetType,
    String targetId, {
    String? seed,
  }) {
    return notes.unlinkEntity(
      commandId: nextCommandId(seed),
      profileId: profileId,
      noteId: NoteId(noteId),
      targetType: targetType,
      targetId: targetId,
    );
  }

  /// Creates a second (inactive) profile with its own life area for
  /// cross-profile ownership tests, and returns its profile id.
  Future<String> insertForeignProfile({
    String id = 'profile-2',
    String areaId = 'area-2',
  }) async {
    await insertProfile(db, id: id, isActive: false);
    await insertLifeArea(db, id, id: areaId, normalizedName: 'career-2');
    return id;
  }

  /// Inserts a minimal open task owned by [ownerProfileId] (defaults to this
  /// harness's profile) directly, for entity-link ownership tests.
  Future<String> insertRawTask({
    required String id,
    String? ownerProfileId,
    String areaId = 'area-1',
  }) async {
    await db.customStatement(
      'INSERT INTO tasks '
      '(id, profile_id, life_area_id, title, status, priority, rank, '
      'created_at_utc, updated_at_utc) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        id,
        ownerProfileId ?? profileId.value,
        areaId,
        'Task $id',
        'open',
        'none',
        'm',
        0,
        0,
      ],
    );
    return id;
  }
}
