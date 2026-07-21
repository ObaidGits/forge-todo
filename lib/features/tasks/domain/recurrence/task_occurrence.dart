/// The current status projection of a materialized occurrence (R-TASK-006).
///
/// The projection is derived from the append-only occurrence event log; it is a
/// convenience column, never the source of truth. Values persist as stable
/// lowercase wire strings with unknown-safe decoding.
enum OccurrenceStatus {
  /// Not yet acted on; the active realization of the series at this key.
  open('open'),

  /// Completed via a completion event.
  completed('completed'),

  /// Skipped/excluded for this key ("this occurrence" delete or EXDATE).
  skipped('skipped'),

  /// Rescheduled/overridden for this key ("this occurrence" edit).
  overridden('overridden'),

  /// The series was cancelled at or before this key.
  cancelled('cancelled');

  const OccurrenceStatus(this.wire);

  final String wire;

  static OccurrenceStatus fromWire(String wire) {
    for (final OccurrenceStatus status in OccurrenceStatus.values) {
      if (status.wire == wire) {
        return status;
      }
    }
    throw FormatException('Unknown occurrence status: $wire');
  }
}

/// The kind of an append-only occurrence event (R-TASK-006, R-TASK-007,
/// R-TASK-009).
///
/// Events are immutable; a later fact never rewrites an earlier one. A
/// correction or undo appends a superseding event that restores the prior
/// visible state while the superseded event stays in the log.
enum OccurrenceEventKind {
  /// The occurrence was completed.
  complete('complete'),

  /// The occurrence was excluded from the series ("this occurrence" delete).
  exception('exception'),

  /// The occurrence was overridden ("this occurrence" edit).
  override('override'),

  /// A superseding correction of a prior event.
  correct('correct'),

  /// A superseding undo restoring the prior visible state.
  undo('undo'),

  /// The series was split with a successor schedule version at this key
  /// ("this and future" edit).
  split('split');

  const OccurrenceEventKind(this.wire);

  final String wire;

  static OccurrenceEventKind fromWire(String wire) {
    for (final OccurrenceEventKind kind in OccurrenceEventKind.values) {
      if (kind.wire == wire) {
        return kind;
      }
    }
    throw FormatException('Unknown occurrence event kind: $wire');
  }
}
