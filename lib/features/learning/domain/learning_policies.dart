import 'package:forge/core/domain/time_span.dart';
import 'package:forge/features/learning/domain/learning_item.dart';
import 'package:forge/features/learning/domain/learning_progress_mode.dart';

/// The derived progress state of a Learning Resource (R-LEARN-004).
///
/// `notStarted` means there is nothing computable — zero eligible items (derived
/// mode) — and is distinct from `0%` of a non-empty set.
final class LearningProgress {
  const LearningProgress._({
    required this.isStarted,
    required this.fraction,
    required this.eligibleCount,
    required this.completedCount,
    required this.mode,
  });

  /// "Not started / no computable progress": zero eligible items in derived
  /// mode.
  static const LearningProgress notStarted = LearningProgress._(
    isStarted: false,
    fraction: 0,
    eligibleCount: 0,
    completedCount: 0,
    mode: LearningProgressMode.derived,
  );

  final bool isStarted;

  /// The progress fraction in `0..1`. Only meaningful when [isStarted].
  final double fraction;
  final int eligibleCount;
  final int completedCount;
  final LearningProgressMode mode;
}

/// The result of resolving the resume point of a Learning Resource
/// (R-LEARN-003).
final class ResumePoint {
  const ResumePoint({required this.itemId, required this.reason});

  /// The eligible incomplete item id to resume, or null when nothing remains.
  final String? itemId;

  /// Why this item was chosen: `last_studied` (the most recent studied item is
  /// still incomplete) or `first_incomplete` (fallback to ordering).
  final String reason;

  static const ResumePoint none = ResumePoint(itemId: null, reason: 'complete');
}

/// Pure learning policies: progress, resume, and interval-union duration
/// (R-LEARN-003, R-LEARN-004, R-LEARN-005, R-FOCUS-005).
///
/// These functions contain no I/O and no clock dependency; callers supply
/// already-loaded items/intervals so the formulas are reproducible on every
/// device and run.
abstract final class LearningPolicies {
  /// Derives progress from [items] under the resource's [mode].
  ///
  /// Derived mode: completed eligible leaves divided by eligible leaves; zero
  /// eligible yields [LearningProgress.notStarted] (R-LEARN-004). Manual mode:
  /// the caller-supplied [manualPermille] clamped to `0..1000`; a manual
  /// resource is always considered started so an explicit 0% is shown as 0%,
  /// not "not started".
  static LearningProgress deriveProgress(
    List<LearningItem> items, {
    LearningProgressMode mode = LearningProgressMode.derived,
    int? manualPermille,
  }) {
    final Iterable<LearningItem> eligible = items.where(
      (LearningItem i) => i.isEligible,
    );
    final int eligibleCount = eligible.length;
    final int completedCount = eligible
        .where((LearningItem i) => i.isComplete)
        .length;

    if (mode == LearningProgressMode.manual) {
      final int clamped = (manualPermille ?? 0).clamp(0, 1000);
      return LearningProgress._(
        isStarted: true,
        fraction: clamped / 1000.0,
        eligibleCount: eligibleCount,
        completedCount: completedCount,
        mode: LearningProgressMode.manual,
      );
    }

    if (eligibleCount == 0) {
      return LearningProgress.notStarted;
    }
    return LearningProgress._(
      isStarted: true,
      fraction: completedCount / eligibleCount,
      eligibleCount: eligibleCount,
      completedCount: completedCount,
      mode: LearningProgressMode.derived,
    );
  }

  /// Resolves the resume point of a resource (R-LEARN-003).
  ///
  /// Resume identifies the last incomplete item the user was working on without
  /// changing it: if the [lastStudiedItemId] (the item of the most recent study
  /// session) is still an eligible incomplete item, it is returned; otherwise
  /// the first eligible incomplete item in rank order is returned. When every
  /// eligible item is complete, [ResumePoint.none] is returned. [items] must be
  /// pre-sorted by ascending rank then id.
  static ResumePoint resolveResume(
    List<LearningItem> items, {
    String? lastStudiedItemId,
  }) {
    if (lastStudiedItemId != null) {
      for (final LearningItem item in items) {
        if (item.id == lastStudiedItemId &&
            item.isEligible &&
            !item.isComplete) {
          return ResumePoint(itemId: item.id, reason: 'last_studied');
        }
      }
    }
    for (final LearningItem item in items) {
      if (item.isEligible && !item.isComplete) {
        return ResumePoint(itemId: item.id, reason: 'first_incomplete');
      }
    }
    return ResumePoint.none;
  }

  /// The total length covered by [spans] (in the caller's unit), merging
  /// overlaps so concurrent time is counted once (R-FOCUS-005, R-LEARN-005).
  ///
  /// This is the study-side duration contract consumed by combined focus/study
  /// metrics: task 7.4 unions focus spans with the study spans returned by the
  /// learning duration contract using the same canonical [IntervalUnion], so
  /// overlapping focus and study time is never double-counted.
  static int unionDuration(List<TimeSpan> spans) =>
      IntervalUnion.unionMicros(spans);
}
