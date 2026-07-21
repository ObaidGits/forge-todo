import 'package:forge/features/tasks/application/task_query_service.dart';

/// A compact progress ring derived from the user's own records (R-HOME-001).
///
/// Every ring names its metric policy version, range, and numerator/denominator
/// and defines its missing-data behaviour, so it is never an opaque score
/// (R-INSIGHT-005, ux-design Data Models). When [total] is zero the ring has no
/// computable value and the view shows "no data" rather than 0%.
final class HomeProgressRing {
  const HomeProgressRing({
    required this.id,
    required this.completed,
    required this.total,
    this.metricPolicyVersion = 'v1',
  });

  /// Stable ring id, e.g. `tasks_today`, used for keys and semantics.
  final String id;

  /// Numerator: completed eligible items.
  final int completed;

  /// Denominator: all eligible items in range.
  final int total;

  final String metricPolicyVersion;

  bool get hasData => total > 0;

  /// Completion fraction in `0..1`, or `0` when there is no data (the view must
  /// consult [hasData] to distinguish "no data" from "0% complete").
  double get fraction => total == 0 ? 0 : completed / total;
}

/// The active study recommendation surfaced on Today (R-HOME-001, R-LEARN-003).
///
/// It names the Learning Resource to resume and, when the resource still has an
/// incomplete item, the resume point resolved without mutating it (R-LEARN-003).
/// It is null when there is nothing to resume, in which case the section
/// collapses (R-HOME-002). Home fills this slot from the learning feature's
/// exported resume contract (design.md §4).
final class StudyRecommendationSlot {
  const StudyRecommendationSlot({
    required this.resourceId,
    required this.title,
    this.resumeItemId,
    this.resumeItemTitle,
    this.reason = 'in_progress',
  });

  /// The Learning Resource to resume (opaque id; opens `/learn/<id>`).
  final String resourceId;

  /// The resource's display title.
  final String title;

  /// The eligible incomplete item to resume, or null when the recommendation is
  /// the resource itself.
  final String? resumeItemId;

  /// The resume item's display title, when [resumeItemId] is set.
  final String? resumeItemTitle;

  /// Why this was chosen: `last_studied`, `first_incomplete`, or `in_progress`.
  final String reason;
}

/// The active focus session surfaced on Today (R-HOME-001, R-HOME-003).
///
/// Focus sessions are started ad hoc rather than scheduled, so there is no
/// "next" session; this slot is present only when a single open (running or
/// paused) session exists and is null otherwise, in which case the focus
/// section offers to start one (R-HOME-002, R-HOME-003). Duration is reported as
/// durable anchors only — the running segment is derived by the timer UI, never
/// stored as a ticking value (R-FOCUS-002).
final class FocusSlot {
  const FocusSlot({
    required this.sessionId,
    required this.statusWire,
    required this.modeWire,
    required this.accumulatedDurationSec,
    this.plannedDurationSec,
    this.linkLabel,
  });

  /// The opaque focus session id (opens `/focus/<id>`).
  final String sessionId;

  /// Stable session status wire value: `running` or `paused`.
  final String statusWire;

  /// Stable session mode wire value: `count_up` or `interval`.
  final String modeWire;

  /// Whole seconds of work completed by previously-closed segments.
  final int accumulatedDurationSec;

  /// The planned length in whole seconds for an interval session; null for a
  /// count-up session.
  final int? plannedDurationSec;

  /// A short label for the linked entity, or null when the session has no link.
  final String? linkLabel;

  bool get isRunning => statusWire == 'running';
  bool get isPaused => statusWire == 'paused';
}

/// A placeholder for today's quick note (R-HOME-001).
///
/// Notes land Wave 4; null in the tasks era.
final class QuickNoteSlot {
  const QuickNoteSlot({required this.noteId, required this.preview});

  final String noteId;
  final String preview;
}

/// A single habit occurrence on Today's checklist (R-HOME-001, R-HOME-003,
/// R-HABIT-003).
///
/// It carries everything the Today check-in control needs to render and act
/// without importing the habits domain: the target kind picks the control
/// (boolean toggle, numeric add, abstinence slip), the status and normalized
/// total describe progress, and the paused flag keeps a paused occurrence
/// neutral rather than a miss (R-HABIT-004, R-HABIT-006). Home fills this from
/// the habits feature's exported `todayChecklist` contract.
final class HabitOccurrenceSlot {
  const HabitOccurrenceSlot({
    required this.habitId,
    required this.title,
    required this.onDateIso,
    required this.occurrenceKey,
    required this.statusWire,
    required this.targetKindWire,
    required this.normalizedTotal,
    required this.isPaused,
    this.targetValue,
    this.unit,
    this.displayUnit,
  });

  final String habitId;
  final String title;

  /// The local date (`YYYY-MM-DD`) this occurrence applies to.
  final String onDateIso;

  /// The deterministic occurrence key (dated ISO date or `week`/`month` key).
  final String occurrenceKey;

  /// Stable occurrence status wire value: `open`, `completed`, `missed`,
  /// `skipped`.
  final String statusWire;

  /// Stable target-kind wire value used to pick the check-in control.
  final String targetKindWire;

  /// Accumulated normalized total for numeric kinds (0 otherwise).
  final int normalizedTotal;

  /// True when this occurrence's anchor is paused; shown as a neutral paused
  /// chip and never treated as a miss (R-HABIT-004).
  final bool isPaused;

  /// The numeric target (canonical seconds for duration, canonical units for
  /// quantity, positive integer for count); null for boolean/abstinence.
  final int? targetValue;

  /// The required unit for a quantity target; null otherwise.
  final String? unit;

  /// The preserved display unit for a duration target; null otherwise.
  final String? displayUnit;

  bool get isCompleted => statusWire == 'completed';
  bool get isSkipped => statusWire == 'skipped';
  bool get isNumeric =>
      targetKindWire == 'count' ||
      targetKindWire == 'duration' ||
      targetKindWire == 'quantity';
}

/// Non-blocking replication status shown as a quiet indicator (R-HOME-005).
///
/// Optional sync lands Wave 8; MVP is local-only. It never blocks content and
/// never replaces cached content with an error.
enum HomeSyncStatus {
  /// No sync configured — all work is local canonical projection.
  localOnly,

  /// Local changes saved; sync pending (Wave 8+).
  pendingSync,

  /// Sync reported an error; content still shown (Wave 8+).
  syncError,
}

/// The fully reconstructed Today content (R-HOME-001).
///
/// Every field is derived from the local Drift generation, so it is available
/// immediately and offline (R-GEN-001, R-HOME-005). Slots for not-yet-shipped
/// modules are empty/null and their sections collapse (R-HOME-002).
final class HomeTodayContent {
  const HomeTodayContent({
    required this.agenda,
    required this.progressRings,
    this.habitOccurrences = const <HabitOccurrenceSlot>[],
    this.studyRecommendation,
    this.focus,
    this.quickNote,
    this.syncStatus = HomeSyncStatus.localOnly,
  });

  const HomeTodayContent.empty()
    : agenda = const TodayAgenda.empty(),
      progressRings = const <HomeProgressRing>[],
      habitOccurrences = const <HabitOccurrenceSlot>[],
      studyRecommendation = null,
      focus = null,
      quickNote = null,
      syncStatus = HomeSyncStatus.localOnly;

  final TodayAgenda agenda;
  final List<HomeProgressRing> progressRings;
  final List<HabitOccurrenceSlot> habitOccurrences;
  final StudyRecommendationSlot? studyRecommendation;
  final FocusSlot? focus;
  final QuickNoteSlot? quickNote;
  final HomeSyncStatus syncStatus;
}
