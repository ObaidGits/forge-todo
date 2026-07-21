import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/features/notes/domain/markdown/safe_markdown.dart';
import 'package:forge/features/notes/domain/note.dart';
import 'package:forge/features/notes/infrastructure/note_write_repository.dart';
import 'package:forge/features/search/application/search_contracts.dart';

/// The note search contributor (R-SEARCH-001, R-NOTE-004).
///
/// A note's searchable content is its title (primary rank field) plus the
/// flattened plain text of its canonical Markdown body. The Markdown is parsed
/// into the safe AST and flattened to plain text, so markup characters, raw
/// HTML and link syntax never pollute the index; code text is included in the
/// body at the lower body weight (design.md §14 `title > body`). The projector
/// lives in the notes feature because it reads authoritative `notes` rows and
/// depends only on the search feature's exported [SearchProjector] contract.
///
/// It is registered into the same transactional [SearchProjectionRegistry] as
/// the task contributor, so `search_documents`, the FTS index and the dirty
/// watermark advance atomically with the note write.
final class NoteSearchProjector implements SearchProjector {
  const NoteSearchProjector();

  static const String kind = 'note';

  @override
  String get entityType => kind;

  @override
  Future<SearchDocumentDraft?> buildDocument(
    TransactionSession session,
    String profileId,
    String entityId,
  ) async {
    final NoteWriteRepository repo = session.repositories
        .resolve<NoteWriteRepository>();
    final Note? note = await repo.find(profileId, entityId);
    if (note == null || note.isDeleted) {
      // Missing or soft-deleted: remove/hide the document transactionally.
      return null;
    }
    return SearchDocumentDraft(
      entityType: entityType,
      entityId: entityId,
      title: note.title,
      body: SafeMarkdown.parse(note.body).toPlainText(),
      sourceRevision: note.revision,
    );
  }

  @override
  Future<List<String>> enumerateEntityIds(
    TransactionSession session,
    String profileId,
  ) async {
    final NoteWriteRepository repo = session.repositories
        .resolve<NoteWriteRepository>();
    return repo.activeIds(profileId);
  }
}
