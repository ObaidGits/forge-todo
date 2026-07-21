import 'package:forge/core/domain/id.dart';
import 'package:forge/features/fitness/domain/measured_quantity.dart';

/// The neutral kind of a body measurement (R-FIT-002, R-FIT-004, R-FIT-005).
///
/// V1 records only body-weight. The kind is deliberately narrow and neutral: no
/// derived health index, no diagnostic category, and no calorie/coaching
/// interpretation is modelled (R-FIT-005 keeps those out of scope).
enum BodyMeasurementKind {
  weight('weight');

  const BodyMeasurementKind(this.wire);

  final String wire;

  static BodyMeasurementKind fromWire(String wire) {
    for (final BodyMeasurementKind kind in BodyMeasurementKind.values) {
      if (kind.wire == wire) {
        return kind;
      }
    }
    throw FormatException('Unknown body measurement kind: $wire');
  }
}

/// A body-weight measurement: a top-level direct-area owner that preserves the
/// entered value/unit while storing a canonical amount (R-FIT-002, R-GEN-002).
///
/// The measurement is a factual record with no medical interpretation
/// (R-FIT-004): it carries the [value] as a [MeasuredQuantity], the instant it
/// was measured, and an optional neutral note.
final class BodyMeasurement {
  const BodyMeasurement({
    required this.id,
    required this.lifeAreaId,
    required this.kind,
    required this.value,
    required this.measuredAtUtc,
    required this.revision,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.note,
    this.deletedAtUtc,
  });

  final BodyMeasurementId id;
  final LifeAreaId lifeAreaId;
  final BodyMeasurementKind kind;
  final MeasuredQuantity value;
  final int measuredAtUtc;
  final String? note;
  final int revision;
  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;

  bool get isDeleted => deletedAtUtc != null;

  BodyMeasurement copyWith({
    MeasuredQuantity? value,
    int? measuredAtUtc,
    String? note,
    bool clearNote = false,
    int? revision,
    int? updatedAtUtc,
    int? deletedAtUtc,
    bool clearDeletedAt = false,
  }) => BodyMeasurement(
    id: id,
    lifeAreaId: lifeAreaId,
    kind: kind,
    value: value ?? this.value,
    measuredAtUtc: measuredAtUtc ?? this.measuredAtUtc,
    note: clearNote ? null : (note ?? this.note),
    revision: revision ?? this.revision,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
    deletedAtUtc: clearDeletedAt ? null : (deletedAtUtc ?? this.deletedAtUtc),
  );
}
