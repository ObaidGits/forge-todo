import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notes/domain/note_link.dart';

import 'note_test_support.dart';

/// Real Drift-backed tests for rename/delete/restore inbound wiki-link
/// integrity — all repaired transactionally in the same commit as the
/// triggering write (R-NOTE-003).
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

  Future<NoteLink> onlyLink(String sourceId) async =>
      (await h.reads.outgoingLinks(h.profileId, NoteId(sourceId))).single;

  group('create re-resolves inbound references (R-NOTE-003)', () {
    test('creating the target binds a previously missing link', () async {
      final String src = await h.createNote(
        title: 'Source',
        body: 'see [[Later]]',
        seed: 's',
      );
      expect((await onlyLink(src)).resolution, WikiLinkResolution.unresolved);

      final String later = await h.createNote(
        title: 'Later',
        body: 'x',
        seed: 'l',
      );
      final NoteLink link = await onlyLink(src);
      expect(link.resolution, WikiLinkResolution.resolved);
      expect(link.targetNoteId!.value, later);
    });

    test(
      'a second same-title note demotes a resolved link to ambiguous',
      () async {
        await h.createNote(title: 'Dup', body: 'a', seed: 'd1');
        final String src = await h.createNote(
          title: 'Source',
          body: 'see [[Dup]]',
          seed: 's',
        );
        expect((await onlyLink(src)).resolution, WikiLinkResolution.resolved);

        await h.createNote(title: 'Dup', body: 'b', seed: 'd2');
        expect((await onlyLink(src)).resolution, WikiLinkResolution.ambiguous);
      },
    );
  });

  group('rename repairs inbound resolution deterministically (R-NOTE-003)', () {
    test('renaming the target unresolves links using the old title', () async {
      final String target = await h.createNote(
        title: 'Old Title',
        body: 'x',
        seed: 't',
      );
      final String src = await h.createNote(
        title: 'Source',
        body: 'see [[Old Title]]',
        seed: 's',
      );
      expect((await onlyLink(src)).resolution, WikiLinkResolution.resolved);

      await h.rename(target, 'New Title', seed: 'rn');
      final NoteLink link = await onlyLink(src);
      expect(link.resolution, WikiLinkResolution.unresolved);
      expect(link.targetNoteId, isNull);
    });

    test(
      'renaming a note into a referenced title binds waiting links',
      () async {
        final String mover = await h.createNote(
          title: 'Placeholder',
          body: 'x',
          seed: 'm',
        );
        final String src = await h.createNote(
          title: 'Source',
          body: 'see [[Destination]]',
          seed: 's',
        );
        expect((await onlyLink(src)).resolution, WikiLinkResolution.unresolved);

        await h.rename(mover, 'Destination', seed: 'rn');
        final NoteLink link = await onlyLink(src);
        expect(link.resolution, WikiLinkResolution.resolved);
        expect(link.targetNoteId!.value, mover);
      },
    );
  });

  group(
    'trash leaves inbound links recoverable and unresolved (R-NOTE-003)',
    () {
      test('trashing the target unresolves the inbound link', () async {
        final String target = await h.createNote(
          title: 'Hub',
          body: 'x',
          seed: 't',
        );
        final String src = await h.createNote(
          title: 'Spoke',
          body: 'see [[Hub]]',
          seed: 's',
        );
        expect((await onlyLink(src)).resolution, WikiLinkResolution.resolved);

        final Result<CommittedCommandResult> del = await h.softDelete(target);
        expect(del, isA<Success<CommittedCommandResult>>());

        // The linking note is never corrupted: the link row survives, its raw
        // text/range are intact, only the resolution is now recoverable.
        final NoteLink link = await onlyLink(src);
        expect(link.resolution, WikiLinkResolution.unresolved);
        expect(link.targetNoteId, isNull);
        expect(link.targetTitle, 'Hub');
        expect(await h.reads.backlinks(h.profileId, NoteId(target)), isEmpty);
      });

      test('restore re-resolves the inbound link', () async {
        final String target = await h.createNote(
          title: 'Hub',
          body: 'x',
          seed: 't',
        );
        final String src = await h.createNote(
          title: 'Spoke',
          body: 'see [[Hub]]',
          seed: 's',
        );
        await h.softDelete(target);
        expect((await onlyLink(src)).resolution, WikiLinkResolution.unresolved);

        await h.restore(target);
        final NoteLink link = await onlyLink(src);
        expect(link.resolution, WikiLinkResolution.resolved);
        expect(link.targetNoteId!.value, target);
        expect(
          await h.reads.backlinks(h.profileId, NoteId(target)),
          hasLength(1),
        );
      });

      test(
        'trashing one of two duplicates collapses ambiguity to a bind',
        () async {
          final String keep = await h.createNote(
            title: 'Dup',
            body: 'a',
            seed: 'd1',
          );
          final String drop = await h.createNote(
            title: 'Dup',
            body: 'b',
            seed: 'd2',
          );
          final String src = await h.createNote(
            title: 'Linker',
            body: 'see [[Dup]]',
            seed: 'lk',
          );
          expect(
            (await onlyLink(src)).resolution,
            WikiLinkResolution.ambiguous,
          );

          await h.softDelete(drop);
          final NoteLink link = await onlyLink(src);
          expect(link.resolution, WikiLinkResolution.resolved);
          expect(link.targetNoteId!.value, keep);
        },
      );
    },
  );
}
