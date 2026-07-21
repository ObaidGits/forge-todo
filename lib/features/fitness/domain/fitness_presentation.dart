/// Non-medical presentation policy for fitness data (R-FIT-004, R-FIT-005).
///
/// Forge fitness is a neutral logbook, not a health product. This policy is the
/// single place that states, and lets tests assert, the boundaries the feature
/// must honor:
///
/// * Charts and summaries SHALL avoid medical interpretation — no diagnosis,
///   risk category, "healthy range", calorie coaching, or derived health index
///   (R-FIT-004, R-FIT-005).
/// * Every displayed aggregate SHALL expose the underlying records it was
///   derived from, so a person always sees the raw logged values behind any
///   chart (R-FIT-004).
/// * Only neutral, factual measurement kinds are modelled; health-platform
///   import is out of scope (R-FIT-005).
///
/// The class holds no state; it documents intent and provides a small guard the
/// query layer and tests can reference so the non-medical guarantee is explicit
/// rather than implicit.
abstract final class FitnessPresentation {
  /// Whether the feature guarantees underlying records are exposed behind every
  /// aggregate (R-FIT-004). Always true; a false value would be a policy
  /// regression that tests catch.
  static const bool exposesUnderlyingRecords = true;

  /// Whether any medical interpretation is applied to fitness data. Always
  /// false (R-FIT-004, R-FIT-005).
  static const bool appliesMedicalInterpretation = false;

  /// Terms that must never appear as derived, interpretive fitness output.
  /// Referenced by presentation tests to guard against medical framing.
  static const List<String> prohibitedInterpretationTerms = <String>[
    'diagnosis',
    'diagnose',
    'bmi',
    'body mass index',
    'healthy weight',
    'overweight',
    'underweight',
    'obese',
    'calorie deficit',
    'calorie coaching',
    'disease risk',
  ];
}
