import 'package:forge/core/domain/id.dart';
import 'package:forge/features/areas/domain/life_area_rank.dart';

/// A Life Area: the profile-owned, area-free taxonomy every top-level
/// classifiable aggregate belongs to (R-GEN-002).
///
/// A Life Area is a pure value reconstructed from the `life_areas` row. It
/// carries a display [name], its lexical [rank] for manual ordering, whether it
/// is the single [isDefault] area a new aggregate inherits, and its archived
/// state. An archived area remains queryable and can still own records — it is
/// simply hidden from the default choosers (R-GEN-002 "Archived areas remain
/// queryable and cannot orphan records").
final class LifeArea {
  LifeArea({
    required this.id,
    required this.profileId,
    required String name,
    required this.rank,
    required this.isDefault,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.archivedAtUtc,
  }) : name = _validateName(name),
       normalizedName = normalizeName(name);

  final LifeAreaId id;
  final ProfileId profileId;
  final String name;
  final String normalizedName;
  final LifeAreaRank rank;
  final bool isDefault;
  final int? archivedAtUtc;
  final int createdAtUtc;
  final int updatedAtUtc;

  bool get isArchived => archivedAtUtc != null;

  LifeArea copyWith({
    String? name,
    LifeAreaRank? rank,
    bool? isDefault,
    Object? archivedAtUtc = _unchanged,
    int? updatedAtUtc,
  }) => LifeArea(
    id: id,
    profileId: profileId,
    name: name ?? this.name,
    rank: rank ?? this.rank,
    isDefault: isDefault ?? this.isDefault,
    archivedAtUtc: identical(archivedAtUtc, _unchanged)
        ? this.archivedAtUtc
        : archivedAtUtc as int?,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );

  /// The maximum accepted display length for an area name.
  static const int maxNameLength = 60;

  /// Normalizes a display name to the case-insensitive uniqueness key stored in
  /// `life_areas.normalized_name`. Collapses internal whitespace and lowercases
  /// so "Personal Growth" and "personal   growth" collide (R-GEN-002 uniqueness
  /// per profile).
  static String normalizeName(String name) =>
      name.trim().toLowerCase().replaceAll(_whitespace, ' ');

  static String _validateName(String name) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Life area name must not be empty.');
    }
    if (trimmed.length > maxNameLength) {
      throw const FormatException('Life area name is too long.');
    }
    return trimmed;
  }

  static const Object _unchanged = Object();
  static final RegExp _whitespace = RegExp(r'\s+');
}
