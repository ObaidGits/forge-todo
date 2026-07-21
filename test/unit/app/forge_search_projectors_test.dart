import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/composition/forge_search_projectors.dart';
import 'package:forge/features/search/application/search_projector.dart';
import 'package:forge/features/search/infrastructure/search_projection_registry.dart';

/// The canonical search projector registry assembled at the composition root
/// (R-SEARCH-001).
///
/// **Validates: Requirements R-SEARCH-001**
///
/// Evidence: [TEST-UNIT-SEARCH-REGISTRY][V1][TASK-10.5]
void main() {
  group('forgeMvpSearchProjectors covers every release-present type', () {
    test('registers exactly the release-present types with no duplicates', () {
      final Set<String> types = forgeMvpSearchProjectors
          .map((SearchProjector p) => p.entityType)
          .toSet();
      // R-SEARCH-001: the MVP indexes tasks, notes, roadmap topics, goals,
      // Learning Resources and habits; V1 additionally adds workouts once the
      // fitness feature exists (task 10.5).
      expect(types, <String>{
        'task',
        'note',
        'goal',
        'roadmap_topic',
        'learning_resource',
        'habit',
        'workout',
      });
      // No duplicate entity types (a duplicate would be a wiring error).
      expect(
        types.length,
        forgeMvpSearchProjectors.length,
        reason: 'each entity type must have exactly one projector',
      );
    });

    test('builds a registry enumerating those types deterministically', () {
      final SearchProjectionRegistry registry = buildForgeSearchRegistry();
      expect(registry.entityTypes, <String>[
        'goal',
        'habit',
        'learning_resource',
        'note',
        'roadmap_topic',
        'task',
        'workout',
      ]);
      // The registry resolves a projector for each registered type.
      for (final String type in registry.entityTypes) {
        expect(registry.projectorFor(type), isNotNull);
      }
      // V1 now routes the workout type; an unregistered type still returns null.
      expect(registry.projectorFor('workout'), isNotNull);
      expect(registry.projectorFor('nonexistent'), isNull);
    });
  });
}
