import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/notes/domain/note_entity_link.dart';

import 'note_test_support.dart';

/// Real Drift-backed tests that a logged workout session participates in the
/// unified note→entity link graph with profile-ownership enforcement (task
/// 10.5, R-FIT-001, R-NOTE-002, R-GEN-002).
///
/// **Validates: Requirements R-FIT-001, R-NOTE-002, R-GEN-002**
///
/// Evidence: [TEST-FIT-LINK-001][V1][TASK-10.5]
void main() {
  late NoteHarness h;

  setUp(() async {
    h = await NoteHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  /// Inserts a raw `workout_sessions` row owned by [ownerProfileId] (defaults to
  /// the harness profile) so links can be validated against a real owner row.
  Future<void> insertRawWorkout({
    required String id,
    String? ownerProfileId,
    String areaId = 'area-1',
    String title = 'Morning push',
  }) async {
    await h.db.customStatement(
      'INSERT INTO workout_sessions '
      '(id, profile_id, life_area_id, title, started_at_utc, revision, '
      'created_at_utc, updated_at_utc) VALUES (?, ?, ?, ?, 0, 1, 0, 0)',
      <Object?>[id, ownerProfileId ?? h.profileId.value, areaId, title],
    );
  }

  test(
    'links a note to a same-profile workout and navigates both ways',
    () async {
      final String note = await h.createNote(title: 'Leg day plan', seed: 'n');
      await insertRawWorkout(id: 'workout-1');

      final Result<CommittedCommandResult> result = await h.linkEntity(
        note,
        NoteEntityTargetType.workout,
        'workout-1',
        seed: 'lk',
      );
      expect(result, isA<Success<CommittedCommandResult>>());

      final List<NoteEntityLink> forward = await h.reads.entityLinksOf(
        h.profileId,
        NoteId(note),
      );
      expect(forward, hasLength(1));
      expect(forward.single.targetType, NoteEntityTargetType.workout);
      expect(forward.single.targetId, 'workout-1');

      final List<NoteEntityLink> reverse = await h.reads.notesLinkingTo(
        h.profileId,
        NoteEntityTargetType.workout,
        'workout-1',
      );
      expect(reverse, hasLength(1));
      expect(reverse.single.noteId.value, note);
    },
  );

  test('a workout owned by another profile is rejected', () async {
    final String note = await h.createNote(title: 'Leg day plan', seed: 'n');
    final String foreign = await h.insertForeignProfile();
    await insertRawWorkout(
      id: 'workout-foreign',
      ownerProfileId: foreign,
      areaId: 'area-2',
    );

    final Result<CommittedCommandResult> result = await h.linkEntity(
      note,
      NoteEntityTargetType.workout,
      'workout-foreign',
      seed: 'x',
    );
    expect(
      (result as Failed<CommittedCommandResult>).failure.code,
      'note.entity_target_not_found',
    );
    // No cross-profile link row was written (R-GEN-002).
    expect(await h.scalar('SELECT COUNT(*) FROM entity_links'), 0);
  });

  test('linking is idempotent and unlink is reversible', () async {
    final String note = await h.createNote(title: 'Leg day plan', seed: 'n');
    await insertRawWorkout(id: 'workout-1');

    await h.linkEntity(
      note,
      NoteEntityTargetType.workout,
      'workout-1',
      seed: 'a',
    );
    await h.linkEntity(
      note,
      NoteEntityTargetType.workout,
      'workout-1',
      seed: 'b',
    );
    expect(
      await h.reads.entityLinksOf(h.profileId, NoteId(note)),
      hasLength(1),
    );

    await h.unlinkEntity(
      note,
      NoteEntityTargetType.workout,
      'workout-1',
      seed: 'u',
    );
    expect(await h.reads.entityLinksOf(h.profileId, NoteId(note)), isEmpty);
  });
}
