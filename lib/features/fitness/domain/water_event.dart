import 'package:forge/core/domain/id.dart';
import 'package:forge/features/fitness/domain/measured_quantity.dart';

/// A single optional water-intake event: a top-level direct-area owner that
/// preserves the entered value/unit while storing a canonical amount
/// (R-FIT-003, R-GEN-002).
///
/// Water tracking is optional and disabled by default (R-FIT-003); a water
/// event is a neutral factual record with no medical interpretation and no
/// calorie/hydration coaching (R-FIT-004, R-FIT-005). The [amount] is a
/// [MeasuredQuantity] in the `volume` dimension, so `500 ml` or `16 floz` is
/// stored verbatim for display and never drifts through rounding, while a
/// canonical microlitre amount is derived for computation and cross-unit
/// history.
final class WaterEvent {
  const WaterEvent({
    required this.id,
    required this.lifeAreaId,
    required this.amount,
    required this.occurredAtUtc,
    required this.revision,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.note,
    this.deletedAtUtc,
  });

  final WaterEventId id;
  final LifeAreaId lifeAreaId;
  final MeasuredQuantity amount;
  final int occurredAtUtc;
  final String? note;
  final int revision;
  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;

  bool get isDeleted => deletedAtUtc != null;

  WaterEvent copyWith({
    MeasuredQuantity? amount,
    int? occurredAtUtc,
    String? note,
    bool clearNote = false,
    int? revision,
    int? updatedAtUtc,
    int? deletedAtUtc,
    bool clearDeletedAt = false,
  }) => WaterEvent(
    id: id,
    lifeAreaId: lifeAreaId,
    amount: amount ?? this.amount,
    occurredAtUtc: occurredAtUtc ?? this.occurredAtUtc,
    note: clearNote ? null : (note ?? this.note),
    revision: revision ?? this.revision,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
    deletedAtUtc: clearDeletedAt ? null : (deletedAtUtc ?? this.deletedAtUtc),
  );
}
