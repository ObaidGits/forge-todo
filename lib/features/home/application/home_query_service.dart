import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/focus/application/focus_today_contract.dart';
import 'package:forge/features/habits/application/habit_query_service.dart';
import 'package:forge/features/home/application/home_content.dart';
import 'package:forge/features/learning/application/learning_resume_contract.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';

/// Composes the Today content from feature application contracts (R-HOME-001).
///
/// It depends only on other features' *application* contracts ([TaskQueryService],
/// [LearningResumeContract], [HabitQueryService], and [FocusTodayContract]),
/// never their domain or infrastructure (design.md §4). Progressive slots are
/// wired here as their features ship; a slot whose contract is not provided is
/// empty/null and its section collapses (R-HOME-002). Everything is
/// reconstructed from Drift and therefore available offline (R-GEN-001,
/// R-HOME-005).
final class HomeQueryService {
  const HomeQueryService(this._tasks, {this.learning, this.habits, this.focus});

  final TaskQueryService _tasks;

  /// The learning feature's exported resume contract, or null before learning
  /// is wired. When present, Today surfaces the active study recommendation
  /// without mutating the resource (R-HOME-001, R-LEARN-003).
  final LearningResumeContract? learning;

  /// The habits feature's exported read contract, or null before habits are
  /// wired. When present, Today surfaces today's habit checklist and a habit
  /// consistency ring (R-HOME-001, R-HABIT-003, R-HABIT-007).
  final HabitQueryService? habits;

  /// The focus feature's exported Today contract, or null before focus is
  /// wired. When present, Today surfaces the active focus session
  /// (R-HOME-001, R-FOCUS-001..003).
  final FocusTodayContract? focus;

  Future<HomeTodayContent> today({
    required ProfileId profileId,
    required String currentPlanningDate,
    required int dayStartUtcMicros,
    required int nowUtcMicros,
    LifeAreaId? lifeAreaId,
  }) async {
    final TodayAgenda agenda = await _tasks.todayAgenda(
      profileId: profileId,
      currentPlanningDate: currentPlanningDate,
      dayStartUtcMicros: dayStartUtcMicros,
      nowUtcMicros: nowUtcMicros,
      lifeAreaId: lifeAreaId,
    );

    final List<HabitOccurrenceSlot> habitSlots = await _habitOccurrences(
      profileId,
      currentPlanningDate,
    );

    return HomeTodayContent(
      agenda: agenda,
      progressRings: <HomeProgressRing>[
        _tasksTodayRing(agenda),
        if (habitSlots.isNotEmpty) _habitsTodayRing(habitSlots),
      ],
      habitOccurrences: habitSlots,
      studyRecommendation: await _studyRecommendation(profileId, lifeAreaId),
      focus: await _focusSlot(profileId, lifeAreaId),
    );
  }

  /// Resolves the Today active-study recommendation from the learning resume
  /// contract, mapping it onto the forward-compatible slot. Null when learning
  /// is not wired or there is nothing to resume (R-HOME-001, R-LEARN-003).
  Future<StudyRecommendationSlot?> _studyRecommendation(
    ProfileId profileId,
    LifeAreaId? lifeAreaId,
  ) async {
    final LearningResumeContract? resume = learning;
    if (resume == null) {
      return null;
    }
    final StudyRecommendation? recommendation = await resume
        .activeStudyRecommendation(profileId, lifeAreaId: lifeAreaId);
    if (recommendation == null) {
      return null;
    }
    return StudyRecommendationSlot(
      resourceId: recommendation.resourceId,
      title: recommendation.resourceTitle,
      resumeItemId: recommendation.resumeItemId,
      resumeItemTitle: recommendation.resumeItemTitle,
      reason: recommendation.reason,
    );
  }

  /// Today's habit occurrences from the habits read contract, mapped onto the
  /// forward-compatible slots. Empty when habits are not wired or nothing is
  /// scheduled today, in which case the section collapses (R-HOME-002).
  Future<List<HabitOccurrenceSlot>> _habitOccurrences(
    ProfileId profileId,
    String currentPlanningDate,
  ) async {
    final HabitQueryService? query = habits;
    if (query == null) {
      return const <HabitOccurrenceSlot>[];
    }
    final List<HabitTodayEntry> entries = await query.todayChecklist(
      profileId: profileId,
      onDate: LocalDate.parse(currentPlanningDate),
    );
    return entries
        .map(
          (HabitTodayEntry e) => HabitOccurrenceSlot(
            habitId: e.habitId,
            title: e.title,
            onDateIso: e.onDateIso,
            occurrenceKey: e.occurrenceKey,
            statusWire: e.statusWire,
            targetKindWire: e.targetKindWire,
            normalizedTotal: e.normalizedTotal,
            isPaused: e.isPaused,
            targetValue: e.targetValue,
            unit: e.unit,
            displayUnit: e.displayUnit,
          ),
        )
        .toList(growable: false);
  }

  /// The active focus session from the focus Today contract, mapped onto the
  /// slot. Null when focus is not wired or no session is open (R-HOME-001,
  /// R-FOCUS-003).
  Future<FocusSlot?> _focusSlot(
    ProfileId profileId,
    LifeAreaId? lifeAreaId,
  ) async {
    final FocusTodayContract? contract = focus;
    if (contract == null) {
      return null;
    }
    final FocusTodaySnapshot? snapshot = await contract.activeSession(
      profileId,
      lifeAreaId: lifeAreaId,
    );
    if (snapshot == null) {
      return null;
    }
    return FocusSlot(
      sessionId: snapshot.sessionId,
      statusWire: snapshot.statusWire,
      modeWire: snapshot.modeWire,
      accumulatedDurationSec: snapshot.accumulatedDurationSec,
      plannedDurationSec: snapshot.plannedDurationSec,
      linkLabel: snapshot.linkLabel,
    );
  }

  /// Tasks-completed-today ring under metric policy v1: numerator is the tasks
  /// completed within the planning day, denominator is the eligible-today set
  /// (overdue + due today + completed today). Zero denominator ⇒ no data.
  HomeProgressRing _tasksTodayRing(TodayAgenda agenda) {
    return HomeProgressRing(
      id: 'tasks_today',
      completed: agenda.completedToday.length,
      total: agenda.plannedTotal,
    );
  }

  /// Habits-completed-today ring under metric policy v1: numerator is completed
  /// eligible occurrences, denominator is all eligible (non-paused) scheduled
  /// occurrences today. Paused occurrences are excluded (R-HABIT-004,
  /// R-HABIT-007). Zero denominator ⇒ no data.
  HomeProgressRing _habitsTodayRing(List<HabitOccurrenceSlot> slots) {
    final Iterable<HabitOccurrenceSlot> eligible = slots.where(
      (HabitOccurrenceSlot s) => !s.isPaused,
    );
    final int total = eligible.length;
    final int completed = eligible
        .where((HabitOccurrenceSlot s) => s.isCompleted)
        .length;
    return HomeProgressRing(
      id: 'habits_today',
      completed: completed,
      total: total,
    );
  }
}
