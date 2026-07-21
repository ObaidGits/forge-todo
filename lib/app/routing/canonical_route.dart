/// Canonical projection route resolution (R-SEARCH-002, R-PLAN-005).
///
/// A search hit, planner reference, or committed capture is addressed only by
/// an `(entityType, entityId)` pair. This resolver maps such a pair to the
/// stable internal route that opens the record's *local canonical projection*
/// (R-SEARCH-002 "open the record's local canonical projection"). It is a pure
/// value: it performs no navigation itself and holds no Flutter/router
/// dependency, so it is exercised directly by unit and integration tests and
/// consumed by presentation.
///
/// The produced paths mirror the opaque-ID route shapes owned by the router and
/// the centralized `UriPolicy` (design.md §7): no content, title, or query text
/// ever appears in the path — only the opaque entity id. Types whose canonical
/// projection requires a parent context (a roadmap topic or a learning item)
/// cannot be addressed by a single id and resolve to `null` rather than a
/// guessed route.
library;

/// The stable entity-type discriminators shared by search projectors, planner
/// references, and capture outcomes. Values match the projector `entityType`
/// and the planner reference wire strings so a single vocabulary threads the
/// whole navigation surface.
abstract final class CanonicalEntityType {
  /// A task (`task` search projector, planner `task` reference).
  static const String task = 'task';

  /// A canonical Markdown note (`note` search projector, planner `note`
  /// reference, R-TASK-010 task note target).
  static const String note = 'note';

  /// A goal (planner `goal` reference; goal search projector lands in a later
  /// wave).
  static const String goal = 'goal';

  /// A Learning Resource. The internal schema retains `course` naming while the
  /// user-facing route is `/learn` (R-LEARN-001).
  static const String learningResource = 'course';

  /// A Learning Resource as emitted by the unified search projector, which uses
  /// the user-facing discriminator rather than the internal `course` name
  /// (R-LEARN-001). Both resolve to the same `/learn` canonical route.
  static const String learningResourceSearch = 'learning_resource';

  /// A roadmap topic as emitted by the unified search projector (R-SEARCH-001).
  /// A topic is not addressable by its own id — its canonical projection is the
  /// roadmap of its owning goal (`/goals/<goalId>/roadmap`), reachable through
  /// [CanonicalRoute.roadmap] once the topic is resolved to its goal.
  static const String roadmapTopic = 'roadmap_topic';

  /// A habit (planner `habit` reference).
  static const String habit = 'habit';

  /// An area-scoped planning record owned by the planner feature (R-PLAN-001).
  static const String planningPeriod = 'planning_period';

  /// A focus session.
  static const String focusSession = 'focus_session';

  /// A workout (V1 fitness).
  static const String workout = 'workout';
}

/// Resolves entity references to their canonical projection route.
abstract final class CanonicalRoute {
  /// The route that opens the canonical projection of the entity identified by
  /// [entityType]/[entityId], or `null` when the type is not directly
  /// addressable (unknown type, or a type that needs a parent context) or the
  /// id is not a well-formed opaque identifier.
  ///
  /// The returned value is an internal route location (e.g. `/notes/<id>`),
  /// never an external URL.
  static String? forEntity(String entityType, String entityId) {
    if (!_isOpaqueId(entityId)) {
      return null;
    }
    final String? base = _base(entityType);
    return base == null ? null : '$base/$entityId';
  }

  /// The canonical route for a planning period (R-PLAN-005). Convenience over
  /// [forEntity] with [CanonicalEntityType.planningPeriod].
  static String? planningPeriod(String periodId) =>
      forEntity(CanonicalEntityType.planningPeriod, periodId);

  /// The canonical projection route for a goal's roadmap,
  /// `/goals/:goalId/roadmap` (R-GOAL-003, R-SEARCH-002). Used to open a
  /// roadmap topic search hit once it has been resolved to its owning goal,
  /// since a topic id alone is not directly addressable. Returns null when
  /// [goalId] is not a well-formed opaque identifier.
  static String? roadmap(String goalId) {
    final String? base = forEntity(CanonicalEntityType.goal, goalId);
    return base == null ? null : '$base/roadmap';
  }

  /// Whether [entityType] has a directly addressable canonical route. Useful
  /// for presentation to decide whether a search hit is openable.
  static bool isAddressable(String entityType) => _base(entityType) != null;

  static String? _base(String entityType) {
    switch (entityType) {
      case CanonicalEntityType.task:
        return '/tasks';
      case CanonicalEntityType.note:
        return '/notes';
      case CanonicalEntityType.goal:
        return '/goals';
      case CanonicalEntityType.learningResource:
      case CanonicalEntityType.learningResourceSearch:
        return '/learn';
      case CanonicalEntityType.habit:
        return '/habits';
      case CanonicalEntityType.planningPeriod:
        return '/planner';
      case CanonicalEntityType.focusSession:
        return '/focus';
      case CanonicalEntityType.workout:
        return '/fitness';
      default:
        return null;
    }
  }

  /// Mirrors the opaque-identifier grammar enforced by `ForgeId`/`UriPolicy`:
  /// a non-empty token of URL-safe characters. Rejects anything with a slash,
  /// whitespace, or content punctuation so no free text can leak into a route.
  static bool _isOpaqueId(String value) => _opaqueId.hasMatch(value);

  static final RegExp _opaqueId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');
}
