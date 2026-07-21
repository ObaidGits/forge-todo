/// The role a referenced entity plays inside a planning record (R-PLAN-002,
/// R-PLAN-003).
///
/// A plan references tasks/goals/habits (and optional Markdown notes) rather
/// than cloning them. Each reference is either originally [planned] into the
/// period, or [carry]-forwarded from an incomplete reference in an earlier
/// period. A carry entry records the carry-forward relation to its source
/// entry so the carried-forward subset is auditable and never double-counted.
enum PlanningEntryRole {
  planned('planned'),
  carry('carry');

  const PlanningEntryRole(this.wire);

  /// Stable lowercase persistence/wire value.
  final String wire;

  /// Decodes a stored [wire] value, throwing [FormatException] for an unknown
  /// value so corrupt persistence surfaces rather than being coerced.
  static PlanningEntryRole fromWire(String wire) {
    for (final PlanningEntryRole role in PlanningEntryRole.values) {
      if (role.wire == wire) {
        return role;
      }
    }
    throw FormatException('Unknown planning entry role: $wire');
  }
}
