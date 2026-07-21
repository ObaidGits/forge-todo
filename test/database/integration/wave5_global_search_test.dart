import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/routing/canonical_route.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/infrastructure/goal_search_projector.dart';
import 'package:forge/features/goals/infrastructure/roadmap_topic_search_projector.dart';
import 'package:forge/features/learning/application/learning_commands.dart';
import 'package:forge/features/learning/infrastructure/learning_search_projector.dart';
import 'package:forge/features/search/domain/search_document.dart';

import 'wave5_integration_support.dart';

/// Real Drift-backed integration proof that the unified global search returns
/// goals, roadmap topics and Learning Resources alongside tasks and notes,
/// grouped by type, and that every hit resolves to the record's canonical
/// projection route (R-SEARCH-001, R-SEARCH-002).
///
/// **Validates: Requirements R-SEARCH-001, R-SEARCH-002**
void main() {
  late Wave5IntegrationHarness h;

  setUp(() async {
    h = await Wave5IntegrationHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  test(
    'a shared term returns all five MVP entity types grouped by type',
    () async {
      final String taskId = await h.createTask('Rust review', seed: 'task');
      final String noteId = await h.createNote('Rust notes', seed: 'note');
      final String goalId = await h.createGoal('Learn Rust', seed: 'goal');
      final String resourceId = await h.createResource(
        'Rust Book',
        seed: 'res',
      );
      final String roadmapId = await h.createRoadmap(goalId, seed: 'rm');
      final String sectionId = await h.addSection(roadmapId, seed: 'sec');
      final String topicId = await h.addTopic(
        sectionId,
        'Rust ownership',
        seed: 'topic',
      );

      final SearchResults results = await h.search.search(h.profileId, 'rust');

      final Set<String> types = results.groups
          .map((SearchResultGroup g) => g.entityType)
          .toSet();
      expect(types, <String>{
        'task',
        'note',
        GoalSearchProjector.kind,
        RoadmapTopicSearchProjector.kind,
        LearningSearchProjector.kind,
      });
      expect(results.totalHits, 5);

      // Every hit opens its canonical projection route.
      for (final SearchResultGroup group in results.groups) {
        final String id = group.hits.single.entityId;
        switch (group.entityType) {
          case 'task':
            expect(id, taskId);
            expect(CanonicalRoute.forEntity('task', id), '/tasks/$taskId');
          case 'note':
            expect(id, noteId);
            expect(CanonicalRoute.forEntity('note', id), '/notes/$noteId');
          case GoalSearchProjector.kind:
            expect(id, goalId);
            expect(CanonicalRoute.forEntity('goal', id), '/goals/$goalId');
          case LearningSearchProjector.kind:
            expect(id, resourceId);
            expect(
              CanonicalRoute.forEntity(LearningSearchProjector.kind, id),
              '/learn/$resourceId',
            );
          case RoadmapTopicSearchProjector.kind:
            expect(id, topicId);
            // A topic is opened through its owning goal's roadmap.
            final GoalId? owner = await h.roadmapReads.goalIdOfTopic(
              h.profileId,
              RoadmapTopicId(id),
            );
            expect(owner?.value, goalId);
            expect(
              CanonicalRoute.roadmap(owner!.value),
              '/goals/$goalId/roadmap',
            );
        }
      }
    },
  );

  test('restricting the search to goals hides other types', () async {
    await h.createTask('Rust review', seed: 'task');
    final String goalId = await h.createGoal('Learn Rust', seed: 'goal');

    final SearchResults goalsOnly = await h.search.search(
      h.profileId,
      'rust',
      types: <String>{GoalSearchProjector.kind},
    );
    expect(goalsOnly.totalHits, 1);
    expect(goalsOnly.groups.single.entityType, GoalSearchProjector.kind);
    expect(goalsOnly.groups.single.hits.single.entityId, goalId);
  });

  test(
    'renaming a Learning Resource re-projects search in the same commit',
    () async {
      final String resourceId = await h.createResource(
        'Draft resource',
        seed: 'res',
      );
      expect((await h.search.search(h.profileId, 'draft')).totalHits, 1);

      await h.learning.updateResource(
        commandId: h.nextCommandId('rename'),
        profileId: h.profileId,
        input: UpdateResourceInput(
          resourceId: resourceId,
          title: 'Published resource',
        ),
      );

      expect((await h.search.search(h.profileId, 'draft')).totalHits, 0);
      final SearchResults renamed = await h.search.search(
        h.profileId,
        'published',
      );
      expect(renamed.totalHits, 1);
      expect(renamed.groups.single.hits.single.entityId, resourceId);
      expect(
        CanonicalRoute.forEntity(LearningSearchProjector.kind, resourceId),
        '/learn/$resourceId',
      );
    },
  );
}
