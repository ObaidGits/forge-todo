/// The period a planning record spans (R-PLAN-001).
///
/// Forge stores exactly one area-scoped planning record per
/// `(profile, life_area, period_type, period_key)`. The [PlanningPeriodKind]
/// is the `period_type`; it selects which named sections a record carries:
///
/// * [day] records have `morning_plan`, `daily_plan`, and `evening_reflection`
///   sections.
/// * [week] and [month] records have `plan_intention` and `reflection` fields.
///
/// This is one record model, not separate planner entities: the kind is a
/// discriminator on a single aggregate, and the schema CHECK constraints keep
/// the non-applicable sections null (data-model §3 "Planning, focus, fitness").
enum PlanningPeriodKind {
  day('day'),
  week('week'),
  month('month');

  const PlanningPeriodKind(this.wire);

  /// Stable lowercase persistence/wire value.
  final String wire;

  /// Decodes a stored [wire] value, throwing [FormatException] for an unknown
  /// value so corrupt persistence surfaces rather than being coerced.
  static PlanningPeriodKind fromWire(String wire) {
    for (final PlanningPeriodKind kind in PlanningPeriodKind.values) {
      if (kind.wire == wire) {
        return kind;
      }
    }
    throw FormatException('Unknown planning period kind: $wire');
  }

  /// Whether this kind uses the named daily sections
  /// (`morning_plan`/`daily_plan`/`evening_reflection`).
  bool get hasDailySections => this == PlanningPeriodKind.day;

  /// Whether this kind uses the aggregate `plan_intention`/`reflection` fields.
  bool get hasAggregateSections =>
      this == PlanningPeriodKind.week || this == PlanningPeriodKind.month;
}
