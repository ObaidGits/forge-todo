import 'package:flutter/material.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

enum ForgeDestination {
  today('/today', Icons.today_outlined, Icons.today),
  tasks('/tasks', Icons.checklist_outlined, Icons.checklist),
  goals('/goals', Icons.flag_outlined, Icons.flag),
  learn('/learn', Icons.school_outlined, Icons.school),
  habits('/habits', Icons.event_repeat_outlined, Icons.event_repeat),
  notes('/notes', Icons.note_outlined, Icons.note),
  planner('/planner', Icons.calendar_month_outlined, Icons.calendar_month),
  focus('/focus', Icons.timer_outlined, Icons.timer),
  settings('/settings', Icons.more_horiz, Icons.more_horiz);

  const ForgeDestination(this.location, this.icon, this.selectedIcon);

  final String location;
  final IconData icon;
  final IconData selectedIcon;

  String label(AppLocalizations strings) => switch (this) {
    ForgeDestination.today => strings.navToday,
    ForgeDestination.tasks => strings.navTasks,
    ForgeDestination.goals => strings.navGoals,
    ForgeDestination.learn => strings.navLearn,
    ForgeDestination.habits => strings.navHabits,
    ForgeDestination.notes => strings.navNotes,
    ForgeDestination.planner => strings.navPlanner,
    ForgeDestination.focus => strings.navFocus,
    ForgeDestination.settings => strings.navMore,
  };

  static ForgeDestination fromLocation(String location) {
    final List<String> segments = location.split('/');
    final String firstSegment = segments.length > 1 ? segments[1] : '';
    return switch (firstSegment) {
      'tasks' => ForgeDestination.tasks,
      'goals' => ForgeDestination.goals,
      'learn' => ForgeDestination.learn,
      'habits' => ForgeDestination.habits,
      'notes' => ForgeDestination.notes,
      'planner' => ForgeDestination.planner,
      'focus' => ForgeDestination.focus,
      'settings' || 'fitness' || 'insights' => ForgeDestination.settings,
      _ => ForgeDestination.today,
    };
  }
}
