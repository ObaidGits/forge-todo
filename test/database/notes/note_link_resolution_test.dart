import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notes/domain/note_link.dart';

import 'note_test_support.dart';

/// Real Drift-backed tests for `[[wiki-link]]` resolution, explicit ambiguity
/// handling, and backlink navigation (R-NOTE-003).
///
/// **Validates: Requirements R-NOTE-003**
void main() {
  late NoteHarness h;

  setUp(() async {
    h = await NoteHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  group('single-match resolution and backlinks (R-NOTE-003)', () {
    test('a unique title resolves forward and provides a backlink', () async {
      final String target = await h.createNote(
        title: 'Target Note',
        body: 'x',
        seed: 't',
      );
      final String src = await h.createNote(
        title: 'Source',
        body: 'refers to [[Target Note]] here',
        seed: 's',
      );

      final List<NoteLink> outgoing = await h.reads.outgoingLinks(
        h.profileId,
        NoteId(src),
      );
      expect(outgoing, hasLength(1));
      expect(outgoing.single.resolution, WikiLinkResolution.resolved);
      expect(outgoing.single.targetNoteId!.value, target);

      final List<NoteLink> backlinks = await h.reads.backlinks(
        h.profileId,
        NoteId(target),
      );
      expect(backlinks, hasLength(1));
      expect(backlinks.single.sourceNoteId.value, src);
    });

    test('a missing title stays unresolved with no backlink', () async {
      final String src = await h.createNote(
        title: 'Lonely',
        body: 'points at [[Nowhere]]',
        seed: 's',
      );
      final NoteLink link = (await h.reads.outgoingLinks(
        h.profileId,
        NoteId(src),
      )).single;
      expect(link.resolution, WikiLinkResolution.unresolved);
      expect(link.targetNoteId, isNull);
    });
  });

  group('explicit ambiguity handling (R-NOTE-003)', () {
    test('two same-title notes make the link ambiguous, not bound', () async {
      await h.createNote(title: 'Dup', body: 'a', seed: 'd1');
      await h.createNote(title: 'Dup', body: 'b', seed: 'd2');
      final String src = await h.createNote(
        title: 'Linker',
        body: 'see [[Dup]]',
        seed: 'lk',
      );

      final NoteLink link = (await h.reads.outgoingLinks(
        h.profileId,
        NoteId(src),
      )).single;
      expect(link.resolution, WikiLinkResolution.ambiguous);
      expect(link.targetNoteId, isNull);
      expect(
        await h.reads.ambiguousLinks(h.profileId, NoteId(src)),
        hasLength(1),
      );
    });

    test(
      'explicit selection binds an ambiguous link to the chosen note',
      () async {
        final String d1 = await h.createNote(
          title: 'Dup',
          body: 'a',
          seed: 'd1',
        );
        await h.createNote(title: 'Dup', body: 'b', seed: 'd2');
        final String src = await h.createNote(
          title: 'Linker',
          body: 'see [[Dup]]',
          seed: 'lk',
        );
        final NoteLink ambiguous = (await h.reads.ambiguousLinks(
          h.profileId,
          NoteId(src),
        )).single;

        // Two candidates are offered for explicit selection.
        expect(
          await h.reads.candidatesForLink(h.profileId, ambiguous.id),
          hasLength(2),
        );

        final Result<CommittedCommandResult> result = await h.resolveLink(
          ambiguous.id,
          d1,
          seed: 'pick',
        );
        expect(result, isA<Success<CommittedCommandResult>>());

        final NoteLink after = (await h.reads.outgoingLinks(
          h.profileId,
          NoteId(src),
        )).single;
        expect(after.resolution, WikiLinkResolution.resolved);
        expect(after.targetNoteId!.value, d1);
        expect(await h.reads.ambiguousLinks(h.profileId, NoteId(src)), isEmpty);
        // The chosen note now has a backlink.
        expect(await h.reads.backlinks(h.profileId, NoteId(d1)), hasLength(1));
      },
    );

    test('selecting a non-candidate note is rejected', () async {
      await h.createNote(title: 'Dup', body: 'a', seed: 'd1');
      await h.createNote(title: 'Dup', body: 'b', seed: 'd2');
      final String other = await h.createNote(
        title: 'Unrelated',
        body: 'z',
        seed: 'o',
      );
      final String src = await h.createNote(
        title: 'Linker',
        body: 'see [[Dup]]',
        seed: 'lk',
      );
      final NoteLink ambiguous = (await h.reads.ambiguousLinks(
        h.profileId,
        NoteId(src),
      )).single;

      final Result<CommittedCommandResult> result = await h.resolveLink(
        ambiguous.id,
        other,
        seed: 'bad',
      );
      final Failure failure =
          (result as Failed<CommittedCommandResult>).failure;
      expect(failure.code, 'note.link_choice_invalid');
      // The link is untouched.
      expect(
        (await h.reads.outgoingLinks(
          h.profileId,
          NoteId(src),
        )).single.resolution,
        WikiLinkResolution.ambiguous,
      );
    });

    test('resolveLink is idempotent on replay of the same command', () async {
      final String d1 = await h.createNote(title: 'Dup', body: 'a', seed: 'd1');
      await h.createNote(title: 'Dup', body: 'b', seed: 'd2');
      final String src = await h.createNote(
        title: 'Linker',
        body: 'see [[Dup]]',
        seed: 'lk',
      );
      final NoteLink ambiguous = (await h.reads.ambiguousLinks(
        h.profileId,
        NoteId(src),
      )).single;

      final CommandId cmd = h.nextCommandId('pick');
      final Result<CommittedCommandResult> first = await h.notes.resolveLink(
        commandId: cmd,
        profileId: h.profileId,
        linkId: ambiguous.id,
        chosenNoteId: NoteId(d1),
      );
      final Result<CommittedCommandResult> replay = await h.notes.resolveLink(
        commandId: cmd,
        profileId: h.profileId,
        linkId: ambiguous.id,
        chosenNoteId: NoteId(d1),
      );
      expect(
        (replay as Success<CommittedCommandResult>).value.replayed,
        isTrue,
      );
      expect(
        (first as Success<CommittedCommandResult>).value.commitSeq,
        replay.value.commitSeq,
      );
    });
  });

  test('a self-referential title does not resolve to itself', () async {
    final String src = await h.createNote(
      title: 'Recursive',
      body: 'links to [[Recursive]]',
      seed: 'r',
    );
    final NoteLink link = (await h.reads.outgoingLinks(
      h.profileId,
      NoteId(src),
    )).single;
    expect(link.resolution, WikiLinkResolution.unresolved);
    expect(link.targetNoteId, isNull);
  });
}
