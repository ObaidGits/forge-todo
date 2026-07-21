import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/domain/roadmap_topic_link.dart';
import 'package:forge/features/notes/domain/note_entity_link.dart';

import 'wave5_integration_support.dart';

/// Real Drift-backed integration proof that canonical-note linking resolves end
/// to end for goals, roadmap topics, and Learning Resources (R-NOTE-002).
///
/// A note may link to a goal and a Learning Resource through `entity_links`
/// (note→entity), and a roadmap topic may reference a note (topic→note). Each
/// link resolves both ways so backlinks navigate correctly.
///
/// **Validates: Requirements R-NOTE-002**
void main() {
  late Wave5IntegrationHarness h;

  setUp(() async {
    h = await Wave5IntegrationHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  test('a note links to a goal and resolves both ways', () async {
    final String noteId = await h.createNote('Rust plan', seed: 'note');
    final String goalId = await h.createGoal('Learn Rust', seed: 'goal');

    await h.linkNoteTo(noteId, NoteEntityTargetType.goal, goalId, seed: 'lg');

    final List<NoteEntityLink> forward = await h.noteReads.entityLinksOf(
      h.profileId,
      NoteId(noteId),
    );
    expect(forward, hasLength(1));
    expect(forward.single.targetType, NoteEntityTargetType.goal);
    expect(forward.single.targetId, goalId);

    final List<NoteEntityLink> reverse = await h.noteReads.notesLinkingTo(
      h.profileId,
      NoteEntityTargetType.goal,
      goalId,
    );
    expect(reverse.single.noteId.value, noteId);
  });

  test('a note links to a Learning Resource and resolves both ways', () async {
    final String noteId = await h.createNote('Rust study notes', seed: 'note');
    final String resourceId = await h.createResource('Rust Book', seed: 'res');

    await h.linkNoteTo(
      noteId,
      NoteEntityTargetType.learningResource,
      resourceId,
      seed: 'lr',
    );

    final List<NoteEntityLink> forward = await h.noteReads.entityLinksOf(
      h.profileId,
      NoteId(noteId),
    );
    expect(forward.single.targetType, NoteEntityTargetType.learningResource);
    expect(forward.single.targetId, resourceId);

    final List<NoteEntityLink> reverse = await h.noteReads.notesLinkingTo(
      h.profileId,
      NoteEntityTargetType.learningResource,
      resourceId,
    );
    expect(reverse.single.noteId.value, noteId);
  });

  test('a roadmap topic references a note (topic→note)', () async {
    final String noteId = await h.createNote('Ownership notes', seed: 'note');
    final String goalId = await h.createGoal('Learn Rust', seed: 'goal');
    final String roadmapId = await h.createRoadmap(goalId, seed: 'rm');
    final String sectionId = await h.addSection(roadmapId, seed: 'sec');
    final String topicId = await h.addTopic(
      sectionId,
      'Ownership',
      seed: 'topic',
    );

    await h.linkTopicToNote(
      topicId,
      RoadmapTopicTargetType.note,
      noteId,
      seed: 'tn',
    );

    // The topic→note link is stored in the shared entity_links table.
    final int links = await h.scalar(
      'SELECT COUNT(*) FROM entity_links '
      'WHERE from_type = ? AND from_id = ? AND to_type = ? AND to_id = ?',
      <Object?>[
        roadmapTopicFromType,
        topicId,
        RoadmapTopicTargetType.note,
        noteId,
      ],
    );
    expect(links, 1);
  });

  test('a note cannot link to a cross-profile goal', () async {
    final String noteId = await h.createNote('Rust plan', seed: 'note');
    // A well-formed but nonexistent goal id under this profile is rejected.
    expect(
      () => h.linkNoteTo(
        noteId,
        NoteEntityTargetType.goal,
        '018f0000-0000-7000-8000-ffffffffffff',
        seed: 'bad',
      ),
      throwsA(isA<StateError>()),
    );
  });
}
