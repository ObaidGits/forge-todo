import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/fitness/domain/body_measurement.dart';
import 'package:forge/features/fitness/domain/fitness_presentation.dart';

/// The non-medical presentation policy is explicit and enforced (R-FIT-004,
/// R-FIT-005).
void main() {
  test('guarantees underlying records are exposed and no interpretation', () {
    expect(FitnessPresentation.exposesUnderlyingRecords, isTrue);
    expect(FitnessPresentation.appliesMedicalInterpretation, isFalse);
  });

  test('body measurement kinds are neutral and factual only', () {
    // V1 models only body-weight; no diagnostic/derived-index kind exists
    // (R-FIT-005 keeps health interpretation out of scope).
    expect(BodyMeasurementKind.values, <BodyMeasurementKind>[
      BodyMeasurementKind.weight,
    ]);
  });

  test('prohibited interpretation terms are named for guard tests', () {
    expect(FitnessPresentation.prohibitedInterpretationTerms, contains('bmi'));
    expect(
      FitnessPresentation.prohibitedInterpretationTerms,
      contains('diagnosis'),
    );
  });
}
