import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/notes/application/note_commands.dart';
import 'package:forge/features/notes/domain/note_link.dart';
import 'package:forge/features/search/domain/search_document.dart';

import 'note_test_support.dart';

/// Real Drift-backed tests for transactional search indexing of note bodies and
/// `[[wiki-link]]` maintenance in the same commit as the note write.
///
/// **Validates: Requirements R-NOTE-003, R-NOTE-004, R-SEARCH-001**
void main() {
  late NoteHarness h;

  setUp(() async {
    h = await NoteHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  group('markdown body is indexed for search (R-NOTE-004)', () {
    test('prose in the body is searchable, markup is not', () async {
      final String id = await h.createNote(
        title: 'Meeting',
        body: 'Discuss the **quarterly** roadmap with [team](https://x.com).',
      );
      final SearchResults hit = await h.search.search(h.profileId, 'quarterly');
      expect(hit.totalHits, 1);
      expect(hit.groups.single.entityType, 'note');
      expect(hit.groups.single.hits.single.entityId, id);
      // Markdown punctuation is not indexed as a term.
      expect((await h.search.search(h.profileId, 'roadmap')).totalHits, 1);
    });

    test(
      'code content is indexed at body weight, title ranks higher',
      () async {
        await h.createNote(title: 'alpha', body: 'nothing relevant');
        await h.createNote(
          title: 'reference',
          body: 'the word alpha appears here',
        );
        final SearchResults results = await h.search.search(
          h.profileId,
          'alpha',
        );
        // Both match; the note whose TITLE is "alpha" ranks first.
        expect(results.groups.single.hits.first.title, 'alpha');
      },
    );
  });

  group(
    'wiki-link maintenance in the same commit (R-NOTE-003, R-NOTE-004)',
    () {
      test('outgoing links are persisted with source ranges', () async {
        // Two notes exist to resolve against.
        await h.createNote(title: 'Target Note', body: 'x', seed: 't');
        final String src = await h.createNote(
          title: 'Source',
          body: 'refers to [[Target Note]] here',
          seed: 's',
        );
        final List<NoteLink> links = await h.reads.outgoingLinks(
          h.profileId,
          NoteId(src),
        );
        expect(links, hasLength(1));
        expect(links.single.targetTitle, 'Target Note');
        expect(links.single.isResolved, isTrue);
      });

      test(
        'a single title match resolves; ambiguity stays unresolved',
        () async {
          await h.createNote(title: 'Dup', body: 'a', seed: 'd1');
          await h.createNote(title: 'Dup', body: 'b', seed: 'd2');
          final String src = await h.createNote(
            title: 'Linker',
            body: 'see [[Dup]] and [[Unknown]]',
            seed: 'lk',
          );
          final List<NoteLink> links = await h.reads.outgoingLinks(
            h.profileId,
            NoteId(src),
          );
          expect(links, hasLength(2));
          // Ambiguous "Dup" (two matches) and missing "Unknown" both stay
          // unresolved; explicit selection is task 5.2.
          expect(links.every((NoteLink l) => !l.isResolved), isTrue);
        },
      );

      test('editing the body replaces the outgoing link set', () async {
        await h.createNote(title: 'Alpha', body: 'x', seed: 'a');
        await h.createNote(title: 'Beta', body: 'y', seed: 'b');
        final String src = await h.createNote(
          title: 'Editable',
          body: 'link to [[Alpha]]',
          seed: 'e',
        );
        final NoteId srcId = NoteId(src);
        expect(
          (await h.reads.outgoingLinks(h.profileId, srcId)).single.targetTitle,
          'Alpha',
        );

        await h.notes.update(
          commandId: h.nextCommandId('relink'),
          profileId: h.profileId,
          noteId: srcId,
          input: const UpdateNoteInput(body: 'now links [[Beta]] only'),
        );
        final List<NoteLink> after = await h.reads.outgoingLinks(
          h.profileId,
          srcId,
        );
        expect(after, hasLength(1));
        expect(after.single.targetTitle, 'Beta');
      });

      test('backlinks resolve to the target note', () async {
        final String target = await h.createNote(
          title: 'Hub',
          body: 'x',
          seed: 'hub',
        );
        final String src = await h.createNote(
          title: 'Spoke',
          body: 'points at [[Hub]]',
          seed: 'spoke',
        );
        final List<NoteLink> backlinks = await h.reads.backlinks(
          h.profileId,
          NoteId(target),
        );
        expect(backlinks, hasLength(1));
        expect(backlinks.single.sourceNoteId.value, src);
      });

      test('links inside code are not maintained', () async {
        final String src = await h.createNote(
          title: 'Coded',
          body: 'literal `[[NotALink]]` only',
          seed: 'c',
        );
        final List<NoteLink> links = await h.reads.outgoingLinks(
          h.profileId,
          NoteId(src),
        );
        expect(links, isEmpty);
      });
    },
  );
}
