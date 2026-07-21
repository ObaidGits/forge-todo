import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/deletion/purge_preview.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/notes/domain/note_link.dart';
import 'package:forge/features/notes/infrastructure/note_repository_factories.dart';
import 'package:forge/features/search/domain/search_document.dart';

import 'note_test_support.dart';

/// Generative property test: across arbitrary create/rename/trash/restore/purge
/// sequences, the unified search index and the `[[wiki-link]]` graph stay
/// mutually consistent — one FTS row per live note, stable row ids, an intact
/// FTS integrity check, every live note findable by title, link resolution that
/// exactly tracks target liveness/title, and never a dangling link into a
/// purged note.
///
/// This complements the example-based [note_link_integrity_test.dart] and the
/// task-only [search_projection_property_test.dart] by exercising the *note*
/// lifecycle — including hard purge — over the combined FTS + link surface.
///
/// **Validates: Requirements R-NOTE-003, R-NOTE-004, R-SEARCH-001, NFR-REL-002**
void main() {
  for (final int seed in <int>[3, 17, 71, 2024]) {
    test('[TEST-NOTE-LIFECYCLE-PROP][MVP][TASK-5.6][R-NOTE-003,R-NOTE-004,'
        'R-SEARCH-001,NFR-REL-002] FTS + links stay consistent across the full '
        'note lifecycle (seed=$seed)', () async {
      final NoteHarness h = await NoteHarness.open();
      addTearDown(h.close);
      final Random random = Random(seed);

      // Four targets and four sources; each source i links to target i by its
      // original (unique) title.
      const int pairs = 4;
      final List<_Target> targets = <_Target>[];
      final Map<int, String> sourceIds = <int, String>{}; // pair -> source id
      int titleCounter = 0;
      int renameCounter = 0;

      String freshTitle() => 'title_${titleCounter++}';

      // Track allocated fts row ids to assert stability.
      final Map<String, int> rowIds = <String, int>{};

      Future<int> visibleDocs() => h.scalar(
        'SELECT COUNT(*) FROM search_documents WHERE deleted = 0 '
        'AND profile_id = ?',
        <Object?>[h.profileId.value],
      );
      Future<int> totalDocs() => h.scalar(
        'SELECT COUNT(*) FROM search_documents WHERE profile_id = ?',
        <Object?>[h.profileId.value],
      );
      Future<int> ftsRows() => h.scalar('SELECT COUNT(*) FROM search_fts');
      Future<int> rowidMappings() =>
          h.scalar('SELECT COUNT(*) FROM fts_rowids');

      Future<Set<String>> searchIds(String term) async {
        final SearchResults results = await h.search.search(h.profileId, term);
        return results.groups
            .expand((SearchResultGroup g) => g.hits)
            .map((SearchHit hit) => hit.entityId)
            .toSet();
      }

      Future<void> assertInvariants() async {
        final int liveTargets = targets
            .where((_Target t) => t.state == _State.live)
            .length;
        // Sources are never deleted in this model.
        final int visibleNotes = liveTargets + sourceIds.length;

        // (1) Only live (non-trashed, non-purged) notes are visible in search;
        // trash hides via the `deleted` flag and purge removes the note row.
        expect(await visibleDocs(), visibleNotes);

        // (2) Mapping integrity holds at every step: there is exactly one FTS
        // row and one stable row-id mapping per search document (a trashed or
        // purged note's document/FTS row is retained and later reclaimed by
        // reconciliation, so these three physical counts always agree).
        final int docs = await totalDocs();
        expect(await ftsRows(), docs, reason: 'one FTS row per document');
        expect(await rowidMappings(), docs, reason: 'one row-id per document');

        // (3) FTS5 internal integrity holds (throws on corruption).
        await h.db.customStatement(
          "INSERT INTO search_fts(search_fts) VALUES('integrity-check')",
        );

        // (4) Row ids are stable per entity across the whole lifecycle.
        for (final _Target t in targets) {
          final Map<String, Object?>? row = await h.firstRow(
            'SELECT fts_rowid FROM fts_rowids WHERE entity_id = ?',
            <Object?>[t.id],
          );
          if (row == null) {
            continue;
          }
          final int rowid = row['fts_rowid'] as int;
          final int? prev = rowIds[t.id];
          if (prev != null) {
            expect(rowid, prev, reason: 'rowid for ${t.id} must be stable');
          }
          rowIds[t.id] = rowid;
        }

        // (5) Live notes are findable by their current title; trashed/purged
        // notes are not returned.
        for (final _Target t in targets) {
          final Set<String> ids = await searchIds(t.currentTitle);
          if (t.state == _State.live) {
            expect(ids, contains(t.id), reason: 'find ${t.currentTitle}');
          } else {
            expect(
              ids,
              isNot(contains(t.id)),
              reason: '${t.state} ${t.id} must not appear in search',
            );
          }
        }

        // (4) Link resolution exactly tracks target liveness + title, and no
        // link ever dangles into a purged note.
        for (final MapEntry<int, String> entry in sourceIds.entries) {
          final _Target target = targets[entry.key];
          final List<NoteLink> links = await h.reads.outgoingLinks(
            h.profileId,
            NoteId(entry.value),
          );
          expect(links, hasLength(1));
          final NoteLink link = links.single;
          final bool shouldResolve =
              target.state == _State.live &&
              target.currentTitle == target.linkedTitle;
          if (shouldResolve) {
            expect(
              link.resolution,
              WikiLinkResolution.resolved,
              reason: 'source->${target.id} should resolve',
            );
            expect(link.targetNoteId!.value, target.id);
          } else {
            expect(
              link.resolution,
              WikiLinkResolution.unresolved,
              reason: 'source->${target.id} should be unresolved',
            );
            expect(link.targetNoteId, isNull);
          }
        }
      }

      // Seed the target/source pairs.
      for (int i = 0; i < pairs; i += 1) {
        final String title = freshTitle();
        final String targetId = await h.createNote(
          title: title,
          body: 'target body',
          seed: 'tgt-$i',
        );
        targets.add(_Target(id: targetId, linkedTitle: title));
        final String sourceId = await h.createNote(
          title: 'source_$i',
          body: 'links to [[$title]]',
          seed: 'src-$i',
        );
        sourceIds[i] = sourceId;
      }
      await assertInvariants();

      for (int step = 0; step < 30; step += 1) {
        final int pair = random.nextInt(pairs);
        final _Target target = targets[pair];
        final int roll = random.nextInt(10);

        if (target.state == _State.purged) {
          continue; // gone for good
        }

        if (target.state == _State.live && roll < 3) {
          // Rename to a brand-new unique title (source link should unresolve).
          final String newTitle = 'renamed_${renameCounter++}';
          await h.rename(target.id, newTitle, seed: 'rn-$step');
          target.currentTitle = newTitle;
        } else if (target.state == _State.live && roll < 7) {
          // Trash it.
          final result = await h.softDelete(target.id);
          expect(result.failureOrNull, isNull);
          target.state = _State.trashed;
        } else if (target.state == _State.trashed && roll < 5) {
          // Restore it.
          final result = await h.restore(target.id);
          expect(result.failureOrNull, isNull);
          target.state = _State.live;
        } else if (target.state == _State.trashed) {
          // Hard purge is blocked while a sync-eligible tombstone still has
          // pending outbox work (R-GEN-003). Simulate the tombstone having
          // replicated and its retention elapsed by clearing the entity's
          // outbox rows, which is the precondition purge requires.
          await h.db.customStatement(
            'DELETE FROM outbox_mutations WHERE profile_id = ? '
            'AND entity_id = ?',
            <Object?>[h.profileId.value, target.id],
          );
          final EntityRef ref = EntityRef(
            entityType: noteTrashableEntityType,
            entityId: target.id,
          );
          final result = await h.deletion.hardPurge(
            command: DurableCommand(
              profileId: h.profileId,
              commandId: h.nextCommandId('purge-$step'),
              commandType: 'note.purge',
              schemaVersion: 1,
              requestHash: 'h-purge-${target.id}-$step',
              canonicalPayload: '{"note_id":"${target.id}"}',
            ),
            refs: <EntityRef>[ref],
            confirmation: PurgeConfirmation.forRefs(<EntityRef>[ref], 1),
          );
          expect(result.failureOrNull, isNull);
          target.state = _State.purged;
        }

        await assertInvariants();
      }
    });
  }
}

enum _State { live, trashed, purged }

final class _Target {
  _Target({required this.id, required this.linkedTitle})
    : currentTitle = linkedTitle;

  final String id;

  /// The title the source note's `[[wiki-link]]` was authored against.
  final String linkedTitle;

  /// The note's current title (diverges from [linkedTitle] after a rename).
  String currentTitle;

  _State state = _State.live;
}
