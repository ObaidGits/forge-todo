import 'package:forge/core/domain/id.dart';
import 'package:forge/features/planner/domain/planning_period_kind.dart';

/// An immutable area-scoped planning record (R-PLAN-001, R-PLAN-004).
///
/// Forge stores exactly one record per
/// `(profile, life_area, period_type, period_key)`. This is one record model,
/// not separate planner entities: [kind] discriminates which named sections
/// carry content.
///
/// * A [PlanningPeriodKind.day] record uses [morningPlanMd], [dailyPlanMd], and
///   [eveningReflectionMd].
/// * A [PlanningPeriodKind.week] or [PlanningPeriodKind.month] record uses
///   [planIntentionMd] and [reflectionMd].
///
/// The non-applicable sections are always null; the constructor rejects a
/// record that carries a section outside its kind, mirroring the schema CHECK
/// constraints (data-model §3). Section bodies are canonical Markdown text;
/// plans reference tasks/goals/habits through separate `planning_entries`
/// rather than cloning them (R-PLAN-002).
///
/// A day record's evening reflection supports configurable, skippable prompts
/// ([eveningPromptsJson]) and private free text ([eveningReflectionMd])
/// (R-PLAN-004). [promptVersion] versions the prompt configuration so an audit
/// can explain which prompt set produced a reflection.
///
/// Ownership is inherited through composite parent keys and area-scoping: the
/// record is a direct-area owner carrying `(profileId, lifeAreaId)`, and its
/// child entries/close records derive the area from it (R-GEN-002).
final class PlanningPeriod {
  PlanningPeriod({
    required this.id,
    required this.profileId,
    required this.lifeAreaId,
    required this.kind,
    required this.periodKey,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.morningPlanMd,
    this.dailyPlanMd,
    this.eveningReflectionMd,
    this.eveningPromptsJson,
    this.planIntentionMd,
    this.reflectionMd,
    this.promptVersion = 1,
    this.revision = 1,
    this.deletedAtUtc,
  }) {
    if (periodKey.trim().isEmpty) {
      throw const FormatException('Planning period key must not be empty.');
    }
    if (promptVersion < 1) {
      throw const FormatException('prompt version must be >= 1.');
    }
    if (!kind.hasDailySections &&
        (morningPlanMd != null ||
            dailyPlanMd != null ||
            eveningReflectionMd != null ||
            eveningPromptsJson != null)) {
      throw FormatException(
        'A ${kind.wire} record must not carry daily sections.',
      );
    }
    if (!kind.hasAggregateSections &&
        (planIntentionMd != null || reflectionMd != null)) {
      throw FormatException(
        'A ${kind.wire} record must not carry aggregate sections.',
      );
    }
  }

  final PlanningPeriodId id;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;
  final PlanningPeriodKind kind;

  /// The stable key identifying the concrete period within [kind]: an ISO
  /// `YYYY-MM-DD` day, an ISO week `YYYY-Www`, or an ISO month `YYYY-MM`.
  final String periodKey;

  /// Named daily sections; non-null only for a [PlanningPeriodKind.day] record.
  final String? morningPlanMd;
  final String? dailyPlanMd;
  final String? eveningReflectionMd;

  /// Canonical JSON describing the configurable, skippable evening reflection
  /// prompts (R-PLAN-004); non-null only for a day record.
  final String? eveningPromptsJson;

  /// Aggregate plan/intention and reflection fields; non-null only for a
  /// [PlanningPeriodKind.week] or [PlanningPeriodKind.month] record.
  final String? planIntentionMd;
  final String? reflectionMd;

  final int promptVersion;

  /// Semantic revision, incremented on each semantic row change (data-model
  /// §1).
  final int revision;

  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;

  bool get isDeleted => deletedAtUtc != null;

  PlanningPeriod copyWith({
    Object? morningPlanMd = _sentinel,
    Object? dailyPlanMd = _sentinel,
    Object? eveningReflectionMd = _sentinel,
    Object? eveningPromptsJson = _sentinel,
    Object? planIntentionMd = _sentinel,
    Object? reflectionMd = _sentinel,
    int? promptVersion,
    int? revision,
    int? updatedAtUtc,
    Object? deletedAtUtc = _sentinel,
  }) {
    return PlanningPeriod(
      id: id,
      profileId: profileId,
      lifeAreaId: lifeAreaId,
      kind: kind,
      periodKey: periodKey,
      morningPlanMd: morningPlanMd == _sentinel
          ? this.morningPlanMd
          : morningPlanMd as String?,
      dailyPlanMd: dailyPlanMd == _sentinel
          ? this.dailyPlanMd
          : dailyPlanMd as String?,
      eveningReflectionMd: eveningReflectionMd == _sentinel
          ? this.eveningReflectionMd
          : eveningReflectionMd as String?,
      eveningPromptsJson: eveningPromptsJson == _sentinel
          ? this.eveningPromptsJson
          : eveningPromptsJson as String?,
      planIntentionMd: planIntentionMd == _sentinel
          ? this.planIntentionMd
          : planIntentionMd as String?,
      reflectionMd: reflectionMd == _sentinel
          ? this.reflectionMd
          : reflectionMd as String?,
      promptVersion: promptVersion ?? this.promptVersion,
      revision: revision ?? this.revision,
      createdAtUtc: createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      deletedAtUtc: deletedAtUtc == _sentinel
          ? this.deletedAtUtc
          : deletedAtUtc as int?,
    );
  }

  /// Passed to [copyWith] for a clearable section to mean "leave unchanged",
  /// distinguishing it from passing `null` to clear the section.
  static const Object unchangedSentinel = _sentinel;

  static const Object _sentinel = Object();
}
