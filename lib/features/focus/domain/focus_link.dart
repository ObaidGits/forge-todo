/// The type of domain entity a focus session may optionally be linked to
/// (R-FOCUS-001).
///
/// A focus session MAY reference exactly one task, Learning Resource, goal, or
/// habit. SQLite cannot foreign-key across entity types, so the polymorphic
/// reference is stored as `(link_target_type, link_target_id)` columns on the
/// session and validated in the writing transaction against the profile-scoped
/// owner table — a cross-profile target is never found and is rejected
/// (R-GEN-002).
enum FocusLinkType {
  task('task'),

  /// A Learning Resource (internal `courses` table, R-LEARN-001).
  learningResource('course'),
  goal('goal'),
  habit('habit');

  const FocusLinkType(this.wire);

  final String wire;

  static FocusLinkType fromWire(String wire) {
    for (final FocusLinkType type in FocusLinkType.values) {
      if (type.wire == wire) {
        return type;
      }
    }
    throw FormatException('Unknown focus link type: $wire');
  }
}

/// An optional link from a focus session to one owning domain entity.
final class FocusLink {
  const FocusLink({required this.type, required this.targetId});

  final FocusLinkType type;
  final String targetId;

  @override
  bool operator ==(Object other) =>
      other is FocusLink && other.type == type && other.targetId == targetId;

  @override
  int get hashCode => Object.hash(type, targetId);

  @override
  String toString() => '${type.wire}:$targetId';
}
