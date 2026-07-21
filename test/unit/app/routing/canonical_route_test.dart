import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/routing/canonical_route.dart';
import 'package:forge/app/routing/uri_policy.dart';

/// Unit coverage for the canonical projection route resolver used by search
/// results, planner navigation, and capture reachability (R-SEARCH-002).
///
/// **Validates: Requirements R-SEARCH-002**
void main() {
  const String id = '018f0000-0000-7000-8000-000000000abc';

  group('directly addressable entity types', () {
    final Map<String, String> expected = <String, String>{
      CanonicalEntityType.task: '/tasks/$id',
      CanonicalEntityType.note: '/notes/$id',
      CanonicalEntityType.goal: '/goals/$id',
      CanonicalEntityType.learningResource: '/learn/$id',
      CanonicalEntityType.habit: '/habits/$id',
      CanonicalEntityType.planningPeriod: '/planner/$id',
      CanonicalEntityType.focusSession: '/focus/$id',
      CanonicalEntityType.workout: '/fitness/$id',
    };

    expected.forEach((String type, String route) {
      test('$type resolves to $route and passes the URI policy', () {
        expect(CanonicalRoute.forEntity(type, id), route);
        expect(CanonicalRoute.isAddressable(type), isTrue);
        expect(UriPolicy().validateRouteLocation(route), isNull);
      });
    });
  });

  test('the planningPeriod helper matches forEntity', () {
    expect(
      CanonicalRoute.planningPeriod(id),
      CanonicalRoute.forEntity(CanonicalEntityType.planningPeriod, id),
    );
  });

  test('unknown or parent-scoped types are not addressable', () {
    expect(CanonicalRoute.forEntity('roadmap_topic', id), isNull);
    expect(CanonicalRoute.forEntity('learning_item', id), isNull);
    expect(CanonicalRoute.forEntity('gizmo', id), isNull);
    expect(CanonicalRoute.isAddressable('gizmo'), isFalse);
  });

  test('a non-opaque id never leaks into a route', () {
    expect(CanonicalRoute.forEntity(CanonicalEntityType.note, ''), isNull);
    expect(CanonicalRoute.forEntity(CanonicalEntityType.note, 'a/b'), isNull);
    expect(
      CanonicalRoute.forEntity(CanonicalEntityType.note, 'has space'),
      isNull,
    );
    expect(
      CanonicalRoute.forEntity(CanonicalEntityType.note, 'note title!'),
      isNull,
    );
  });
}
