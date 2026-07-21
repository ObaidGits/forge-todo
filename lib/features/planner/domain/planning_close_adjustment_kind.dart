/// Why a linked adjustment was appended to an immutable factual close
/// (R-PLAN-003, R-HABIT-005).
///
/// A planning period has exactly one idempotent, immutable factual close
/// snapshot, independent of policy version. It is never rewritten. Instead:
///
/// * [sourceCorrection] records a later correction to a source event (for
///   example a task completion recorded after close, or a superseding habit
///   check-in). The correction is appended as a linked adjustment carrying the
///   prior/current classification delta.
/// * [policyRecomputation] records a recalculation under a newer metric policy.
///   It produces a separate derived recomputation/cache record and never
///   creates or replaces a factual close.
enum PlanningCloseAdjustmentKind {
  sourceCorrection('source_correction'),
  policyRecomputation('policy_recomputation');

  const PlanningCloseAdjustmentKind(this.wire);

  /// Stable lowercase persistence/wire value.
  final String wire;

  /// Decodes a stored [wire] value, throwing [FormatException] for an unknown
  /// value so corrupt persistence surfaces rather than being coerced.
  static PlanningCloseAdjustmentKind fromWire(String wire) {
    for (final PlanningCloseAdjustmentKind kind
        in PlanningCloseAdjustmentKind.values) {
      if (kind.wire == wire) {
        return kind;
      }
    }
    throw FormatException('Unknown planning close adjustment kind: $wire');
  }
}
