import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/features/notes/infrastructure/attachment_repository.dart';
import 'package:forge/features/notes/infrastructure/note_repository_factories.dart';
import 'package:forge/features/notes/infrastructure/staged_attachment_store.dart';

import '../../../helpers/fake_attachment_crypto.dart';
import '../../../helpers/fake_key_vault.dart';
import '../../../helpers/fake_managed_file_system.dart';
import '../../schema/schema_test_database.dart';
import '../../tasks/task_test_support.dart';

/// A minimal PNG header + payload for a valid accepted attachment.
final List<int> validPngBytes = <int>[
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // PNG magic
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, // IHDR...
  0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
];

/// A minimal PDF header + payload for a non-preview-safe accepted type... note:
/// PDF is on the preview allowlist; used for external-open tests.
final List<int> validPdfBytes = <int>[
  0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34, // %PDF-1.4
  0x0a, 0x25, 0x0a, 0x31, 0x20, 0x30, 0x20, 0x6f,
];

/// Bytes with no recognised magic signature (rejected as unsupported type).
final List<int> unknownBytes = <int>[
  0x00,
  0x01,
  0x02,
  0x03,
  0x04,
  0x05,
  0x06,
  0x07,
  0x08,
  0x09,
  0x0a,
  0x0b,
  0x0c,
  0x0d,
  0x0e,
  0x0f,
];

/// Real Drift-backed wiring for the managed-attachment pipeline.
final class AttachmentHarness {
  AttachmentHarness._(
    this.db,
    this.profileId,
    this.noteId,
    this.store,
    this.fileSystem,
    this.crypto,
    this.keyVault,
    this.reads,
  );

  static Future<AttachmentHarness> open({
    List<int> kek = const <int>[9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2],
  }) async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    final String profileId = await insertProfile(db);
    await insertLifeArea(db, profileId, id: 'area-1');
    await _insertNote(db, profileId, noteId: 'note-1', areaId: 'area-1');

    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: noteRepositoryFactories,
    );
    final AttachmentReadRepository reads = AttachmentReadRepository(db);
    final FakeManagedFileSystem fs = FakeManagedFileSystem();
    final FakeAttachmentCrypto crypto = FakeAttachmentCrypto();
    final FakeKeyVault keyVault = FakeKeyVault.available(kek);
    int tick = 0;
    final StagedAttachmentStore store = StagedAttachmentStore(
      unitOfWork: unitOfWork,
      reads: reads,
      fileSystem: fs,
      crypto: crypto,
      keyVault: keyVault,
      now: () => DateTime.utc(2024, 6, 1).add(Duration(seconds: tick++)),
    );
    return AttachmentHarness._(
      db,
      profileId,
      'note-1',
      store,
      fs,
      crypto,
      keyVault,
      reads,
    );
  }

  final ForgeSchemaDatabase db;
  final String profileId;
  final String noteId;
  final StagedAttachmentStore store;
  final FakeManagedFileSystem fileSystem;
  final FakeAttachmentCrypto crypto;
  final FakeKeyVault keyVault;
  final AttachmentReadRepository reads;

  Future<void> close() => db.close();

  Future<List<Map<String, Object?>>> journalRows() async {
    final List<QueryRow> rows = await db
        .customSelect('SELECT * FROM file_journal ORDER BY id')
        .get();
    return rows.map((QueryRow r) => r.data).toList(growable: false);
  }

  Future<Map<String, Object?>?> attachmentRow(String id) async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT * FROM attachments WHERE id = ?',
          variables: <Variable<Object>>[Variable<String>(id)],
        )
        .get();
    return rows.isEmpty ? null : rows.first.data;
  }

  /// Records a raw file-journal row directly, to reconstruct the on-disk state
  /// left behind by an unexpected process termination for recovery tests.
  Future<void> recordJournal({
    required String id,
    required String operation,
    required String state,
    required String token,
    String ownerEntityType = 'note',
    String ownerEntityId = 'note-1',
  }) async {
    await db.customStatement(
      'INSERT INTO file_journal '
      '(id, profile_id, owner_entity_type, owner_entity_id, operation, '
      'staged_path_token, final_path_token, state, created_at_utc, '
      'updated_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0)',
      <Object?>[
        id,
        profileId,
        ownerEntityType,
        ownerEntityId,
        operation,
        token,
        token,
        state,
      ],
    );
  }

  /// Forces a journal row into [state], to simulate a crash that left the
  /// journal non-terminal.
  Future<void> setJournalState(String id, String state) async {
    await db.customStatement(
      'UPDATE file_journal SET state = ? WHERE id = ?',
      <Object?>[state, id],
    );
  }

  Future<String?> journalState(String id) async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT state FROM file_journal WHERE id = ?',
          variables: <Variable<Object>>[Variable<String>(id)],
        )
        .get();
    return rows.isEmpty ? null : rows.first.data['state'] as String?;
  }
}

Future<void> _insertNote(
  ForgeSchemaDatabase db,
  String profileId, {
  required String noteId,
  required String areaId,
}) async {
  await db.customStatement(
    'INSERT INTO notes '
    '(id, profile_id, life_area_id, title, normalized_title, body, '
    'content_hash, pinned, rank, revision, created_at_utc, updated_at_utc) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, 1, 0, 0)',
    <Object?>[noteId, profileId, areaId, 'Note', 'note', 'body', 'hash', 'm'],
  );
}
