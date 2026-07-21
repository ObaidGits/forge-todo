import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/notes/domain/note.dart';
import 'package:forge/features/notes/domain/note_rank.dart';

/// Explicit mapping between the `notes` Drift row and the immutable [Note]
/// domain aggregate (design.md "Data Models").
abstract final class NoteMapper {
  static Note fromRow(NoteRow row) {
    return Note(
      id: NoteId(row.id),
      profileId: ProfileId(row.profileId),
      lifeAreaId: LifeAreaId(row.lifeAreaId),
      title: row.title,
      body: row.body,
      contentHash: row.contentHash,
      pinned: row.pinned,
      archivedAtUtc: row.archivedAtUtc,
      rank: NoteRank(row.rank),
      revision: row.revision,
      createdAtUtc: row.createdAtUtc,
      updatedAtUtc: row.updatedAtUtc,
      deletedAtUtc: row.deletedAtUtc,
    );
  }

  static NotesCompanion toInsert(
    Note note, {
    required String normalizedTitle,
  }) => NotesCompanion.insert(
    id: note.id.value,
    profileId: note.profileId.value,
    lifeAreaId: note.lifeAreaId.value,
    title: note.title,
    normalizedTitle: normalizedTitle,
    body: note.body,
    contentHash: note.contentHash,
    pinned: Value<bool>(note.pinned),
    archivedAtUtc: Value<int?>(note.archivedAtUtc),
    rank: note.rank.value,
    revision: Value<int>(note.revision),
    createdAtUtc: note.createdAtUtc,
    updatedAtUtc: note.updatedAtUtc,
    deletedAtUtc: Value<int?>(note.deletedAtUtc),
  );

  /// Builds a full-row update companion. Every mutable column is written so the
  /// row exactly matches the aggregate.
  static NotesCompanion toUpdate(
    Note note, {
    required String normalizedTitle,
  }) => NotesCompanion(
    lifeAreaId: Value<String>(note.lifeAreaId.value),
    title: Value<String>(note.title),
    normalizedTitle: Value<String>(normalizedTitle),
    body: Value<String>(note.body),
    contentHash: Value<String>(note.contentHash),
    pinned: Value<bool>(note.pinned),
    archivedAtUtc: Value<int?>(note.archivedAtUtc),
    rank: Value<String>(note.rank.value),
    revision: Value<int>(note.revision),
    updatedAtUtc: Value<int>(note.updatedAtUtc),
    deletedAtUtc: Value<int?>(note.deletedAtUtc),
  );
}
