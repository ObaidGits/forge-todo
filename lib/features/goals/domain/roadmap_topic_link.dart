/// Linking a roadmap topic to another domain entity through `entity_links`
/// (R-GOAL-003, R-GEN-002).
///
/// A topic MAY reference tasks, notes, and Learning Resources. SQLite cannot
/// foreign-key across entity types, so these polymorphic references live in the
/// shared `entity_links` table and are validated in the writing transaction
/// against a centralized owner registry (data-model §1). Because every
/// existence check is profile-scoped, a cross-profile target is never found and
/// the link is rejected (R-GEN-002).
library;

/// The `entity_links.from_type` value for a roadmap topic reference.
const String roadmapTopicFromType = 'roadmap_topic';

/// The stable `entity_links.relation` value for a roadmap topic reference.
const String roadmapTopicLinkRelation = 'roadmap_topic_reference';

/// Recognized link target types for a roadmap topic (R-GOAL-003).
abstract final class RoadmapTopicTargetType {
  static const String task = 'task';
  static const String note = 'note';
  static const String learningResource = 'learning_resource';

  static const Set<String> all = <String>{task, note, learningResource};
}

/// The outcome of a topic link attempt (mirrors the note link outcome).
enum RoadmapTopicLinkOutcome {
  linked,
  alreadyLinked,
  topicMissing,
  targetTypeUnknown,
  targetTypeUnavailable,
  targetMissing,
}
