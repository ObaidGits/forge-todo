import 'package:forge/core/domain/id.dart';

/// A read model of one Life Area for presentation (R-GEN-002).
///
/// Presentation renders and orders areas from this immutable summary; the
/// durable [LifeArea] domain value never crosses the application boundary.
final class LifeAreaSummary {
  const LifeAreaSummary({
    required this.id,
    required this.name,
    required this.rank,
    required this.isDefault,
    required this.isArchived,
  });

  final LifeAreaId id;
  final String name;

  /// The lexical ordering rank; summaries arrive already sorted by rank then id.
  final String rank;
  final bool isDefault;
  final bool isArchived;
}

/// Application query facade for Life Areas (R-GEN-002).
///
/// Results are reconstructed from the active local generation, so they are
/// available offline (R-GEN-001). Archived areas are included so management UI
/// can restore them and so nothing is silently orphaned.
abstract interface class LifeAreaQueryService {
  /// Every non-deleted Life Area for [profileId], ordered by rank then id.
  /// [includeArchived] controls whether archived areas are returned.
  Future<List<LifeAreaSummary>> list(
    ProfileId profileId, {
    bool includeArchived = true,
  });
}
