/// The kind of entity a planning entry references (R-PLAN-002).
///
/// Plans reference tasks/goals/habits and optional Markdown notes rather than
/// clone them. The reference is polymorphic: `planning_entries` stores an
/// `(entity_type, entity_id)` pair validated by the centralized owner registry
/// in the writing transaction (data-model §1). Only these release-present
/// referenceable types are permitted.
enum PlanningReferenceType {
  task('task'),
  goal('goal'),
  habit('habit'),
  note('note');

  const PlanningReferenceType(this.wire);

  /// Stable lowercase persistence/wire value.
  final String wire;

  /// Decodes a stored [wire] value, throwing [FormatException] for an unknown
  /// value so corrupt persistence surfaces rather than being coerced.
  static PlanningReferenceType fromWire(String wire) {
    for (final PlanningReferenceType type in PlanningReferenceType.values) {
      if (type.wire == wire) {
        return type;
      }
    }
    throw FormatException('Unknown planning reference type: $wire');
  }
}
