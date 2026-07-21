import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/routing/canonical_route.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/notes/application/note_commands.dart';
import 'package:forge/features/search/domain/search_document.dart';

import 'notes_integration_support.dart';

/// Real Drift-backed integration proof that the unified global search returns
/// both tasks and notes, grouped by type, and that every hit resolves to the
/// canonical projection route so it opens the record's local canonical
/// projection (R-SEARCH-001, R-SEARCH-002).
///
/// **Validates: Requirements R-SEARCH-001, R-SEARCH-002**
void main() {
  late NotesIntegrationHarness h;

  setUp(() async {
    h = await NotesIntegrationHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  test(
    'a term matching a task and a note returns both, grouped by type',
    () async {
      final String taskId = await h.createTask('Roadmap review', seed: 'task');
      final String noteId = await h.createNote(
        'Roadmap notes',
        body: 'Longer term roadmap thinking.',
        seed: 'note',
      );

      final SearchResults results = await h.search.search(
        h.profileId,
        'roadmap',
      );

      // Grouped by type: exactly one task group and one note group.
      final Set<String> types = results.groups
          .map((SearchResultGroup g) => g.entityType)
          .toSet();
      expect(types, <String>{'task', 'note'});
      expect(results.totalHits, 2);

      // Each hit opens the record's canonical projection.
      for (final SearchResultGroup group in results.groups) {
        final String id = group.hits.single.entityId;
        final String? route = CanonicalRoute.forEntity(group.entityType, id);
        expect(route, isNotNull);
        if (group.entityType == 'note') {
          expect(id, noteId);
          expect(route, '/notes/$noteId');
        } else {
          expect(id, taskId);
          expect(route, '/tasks/$taskId');
        }
      }
    },
  );

  test('note body prose is indexed and opens the canonical note', () async {
    final String noteId = await h.createNote(
      'Meeting',
      body: 'Discuss the **quarterly** budget with the team.',
      seed: 'note',
    );

    final SearchResults results = await h.search.search(
      h.profileId,
      'quarterly',
    );
    expect(results.totalHits, 1);
    final SearchResultGroup group = results.groups.single;
    expect(group.entityType, 'note');
    expect(group.hits.single.entityId, noteId);
    // The note result opens the note's canonical projection.
    expect(
      CanonicalRoute.forEntity(group.entityType, group.hits.single.entityId),
      '/notes/$noteId',
    );
  });

  test('restricting the search to notes hides task hits', () async {
    await h.createTask('Quarterly planning', seed: 'task');
    final String noteId = await h.createNote('Quarterly retro', seed: 'note');

    final SearchResults notesOnly = await h.search.search(
      h.profileId,
      'quarterly',
      types: <String>{'note'},
    );
    expect(notesOnly.groups.single.entityType, 'note');
    expect(notesOnly.totalHits, 1);
    expect(notesOnly.groups.single.hits.single.entityId, noteId);
  });

  test(
    'renaming a note re-projects the search index in the same commit',
    () async {
      final String noteId = await h.createNote('Draft title', seed: 'note');
      expect((await h.search.search(h.profileId, 'draft')).totalHits, 1);

      await h.notes.update(
        commandId: h.nextCommandId('rename'),
        profileId: h.profileId,
        noteId: NoteId(noteId),
        input: const UpdateNoteInput(title: 'Published title'),
      );

      // The old term no longer matches; the new term does — proving the note's
      // search document advanced atomically with the note write.
      expect((await h.search.search(h.profileId, 'draft')).totalHits, 0);
      final SearchResults renamed = await h.search.search(
        h.profileId,
        'published',
      );
      expect(renamed.totalHits, 1);
      expect(renamed.groups.single.hits.single.entityId, noteId);
      expect(CanonicalRoute.forEntity('note', noteId), '/notes/$noteId');
    },
  );
}
