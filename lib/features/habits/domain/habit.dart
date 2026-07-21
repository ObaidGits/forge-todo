import 'package:forge/core/domain/id.dart';

/// The lifecycle status of a habit aggregate.
enum HabitStatus {
  active('active'),
  archived('archived');

  const HabitStatus(this.wire);

  final String wire;

  static HabitStatus fromWire(String wire) {
    for (final HabitStatus status in HabitStatus.values) {
      if (status.wire == wire) {
        return status;
      }
    }
    throw FormatException('Unknown habit status: $wire');
  }
}

/// A habit: a top-level direct-area owner whose behavior is defined by a chain
/// of immutable schedule/target versions (R-HABIT-001, R-GEN-002).
///
/// The habit row is a thin pointer at the current schedule version plus
/// classification and ordering; all cadence and target semantics live in the
/// immutable [currentScheduleVersionId] version and its predecessors, and all
/// realized behavior lives in occurrences and append-only check-ins.
final class Habit {
  const Habit({
    required this.id,
    required this.lifeAreaId,
    required this.title,
    required this.currentScheduleVersionId,
    required this.rank,
    required this.status,
    required this.revision,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.pausedAtUtc,
    this.deletedAtUtc,
  });

  final HabitId id;
  final LifeAreaId lifeAreaId;
  final String title;

  /// The id of the immutable schedule/target version currently in effect.
  final String currentScheduleVersionId;

  final String rank;
  final HabitStatus status;
  final int revision;
  final int createdAtUtc;
  final int updatedAtUtc;

  /// When set, the habit is currently paused (occurrences from here are
  /// ineligible for metrics until resumed).
  final int? pausedAtUtc;

  final int? deletedAtUtc;

  bool get isDeleted => deletedAtUtc != null;
  bool get isPaused => pausedAtUtc != null;

  Habit copyWith({
    String? currentScheduleVersionId,
    String? title,
    String? rank,
    HabitStatus? status,
    int? revision,
    int? updatedAtUtc,
    int? pausedAtUtc,
    bool clearPausedAt = false,
    int? deletedAtUtc,
    bool clearDeletedAt = false,
  }) => Habit(
    id: id,
    lifeAreaId: lifeAreaId,
    title: title ?? this.title,
    currentScheduleVersionId:
        currentScheduleVersionId ?? this.currentScheduleVersionId,
    rank: rank ?? this.rank,
    status: status ?? this.status,
    revision: revision ?? this.revision,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
    pausedAtUtc: clearPausedAt ? null : (pausedAtUtc ?? this.pausedAtUtc),
    deletedAtUtc: clearDeletedAt ? null : (deletedAtUtc ?? this.deletedAtUtc),
  );
}
