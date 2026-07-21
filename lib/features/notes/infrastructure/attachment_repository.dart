import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/notes/domain/attachments/attachment.dart';

/// Published-attachment accounting totals for one profile (quota checks).
final class AttachmentTotals {
  const AttachmentTotals({required this.bytes, required this.count});

  final int bytes;
  final int count;
}

Attachment _mapRow(AttachmentRow row) => Attachment(
  id: row.id,
  profileId: row.profileId,
  noteId: row.noteId,
  displayName: row.displayName,
  declaredMime: row.declaredMime,
  detectedMime: row.detectedMime,
  byteSize: row.byteSize,
  contentHash: row.contentHash,
  wrappedDek: row.wrappedDek,
  cipherVersion: row.cipherVersion,
  pathToken: row.pathToken,
  state: AttachmentStateWire.fromWire(row.state),
  createdAtUtc: row.createdAtUtc,
  updatedAtUtc: row.updatedAtUtc,
  deletedAtUtc: row.deletedAtUtc,
);

/// Transaction-scoped writes for managed attachments (R-NOTE-006). Publication
/// and soft-deletion run inside the same transaction as the durable file
/// journal advance, so metadata and journal state are always consistent.
final class AttachmentWriteRepository {
  AttachmentWriteRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;

  /// Inserts a published attachment row. The unique `(profile_id, path_token)`
  /// and `(profile_id, id)` constraints reject duplicates at the boundary.
  Future<void> insertPublished(Attachment attachment) async {
    scope.ensureActive();
    await db
        .into(db.attachments)
        .insert(
          AttachmentsCompanion.insert(
            id: attachment.id,
            profileId: attachment.profileId,
            noteId: attachment.noteId,
            displayName: attachment.displayName,
            declaredMime: attachment.declaredMime,
            detectedMime: attachment.detectedMime,
            byteSize: attachment.byteSize,
            contentHash: attachment.contentHash,
            wrappedDek: attachment.wrappedDek,
            cipherVersion: attachment.cipherVersion,
            pathToken: attachment.pathToken,
            state: Value<String>(attachment.state.wire),
            createdAtUtc: attachment.createdAtUtc,
            updatedAtUtc: attachment.updatedAtUtc,
            deletedAtUtc: Value<int?>(attachment.deletedAtUtc),
          ),
        );
  }

  /// Marks a published attachment `deleted`. Idempotent; returns the number of
  /// rows affected.
  Future<int> markDeleted({
    required String profileId,
    required String attachmentId,
    required int nowUtc,
  }) async {
    scope.ensureActive();
    return db.customUpdate(
      "UPDATE attachments SET state = 'deleted', deleted_at_utc = ?, "
      'updated_at_utc = ? WHERE profile_id = ? AND id = ? '
      "AND state = 'published'",
      variables: <Variable<Object>>[
        Variable<int>(nowUtc),
        Variable<int>(nowUtc),
        Variable<String>(profileId),
        Variable<String>(attachmentId),
      ],
      updates: <TableInfo<Table, Object?>>{db.attachments},
    );
  }

  /// Published byte total and count for [profileId] (quota accounting).
  Future<AttachmentTotals> publishedTotals(String profileId) =>
      _totals(db, profileId);
}

/// Non-transactional reads for managed attachments.
final class AttachmentReadRepository {
  AttachmentReadRepository(this.db);

  final ForgeSchemaDatabase db;

  Future<Attachment?> find({
    required String profileId,
    required String attachmentId,
  }) async {
    final AttachmentRow? row =
        await (db.select(db.attachments)..where(
              (Attachments t) =>
                  t.profileId.equals(profileId) & t.id.equals(attachmentId),
            ))
            .getSingleOrNull();
    return row == null ? null : _mapRow(row);
  }

  Future<List<Attachment>> publishedForProfile(String profileId) async {
    final List<AttachmentRow> rows =
        await (db.select(db.attachments)..where(
              (Attachments t) =>
                  t.profileId.equals(profileId) &
                  t.state.equals(AttachmentState.published.wire),
            ))
            .get();
    return rows.map(_mapRow).toList(growable: false);
  }

  Future<AttachmentTotals> publishedTotals(String profileId) =>
      _totals(db, profileId);
}

Future<AttachmentTotals> _totals(
  ForgeSchemaDatabase db,
  String profileId,
) async {
  final List<QueryRow> rows = await db
      .customSelect(
        'SELECT COALESCE(SUM(byte_size), 0) AS bytes, COUNT(*) AS n '
        'FROM attachments WHERE profile_id = ? AND state = ?',
        variables: <Variable<Object>>[
          Variable<String>(profileId),
          Variable<String>(AttachmentState.published.wire),
        ],
      )
      .get();
  final Map<String, Object?> row = rows.single.data;
  return AttachmentTotals(
    bytes: (row['bytes'] as int?) ?? 0,
    count: (row['n'] as int?) ?? 0,
  );
}
