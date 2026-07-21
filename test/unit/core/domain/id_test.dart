import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';

void main() {
  test('typed IDs preserve valid opaque values and type identity', () {
    final List<ForgeId> ids = <ForgeId>[
      ProfileId('profile_01'),
      LifeAreaId('area-01'),
      CommandId('018f_uuid_v7'),
      DeviceId('device_01'),
      GenerationId('generation_01'),
      TaskId('task_01'),
      NoteId('note_01'),
      GoalId('goal_01'),
      LearningResourceId('resource_01'),
      HabitId('habit_01'),
      PlanningPeriodId('period_01'),
      FocusSessionId('focus_01'),
      WorkoutId('workout_01'),
      FilterId('filter_01'),
      AttachmentId('attachment_01'),
    ];

    for (final ForgeId id in ids) {
      expect(id.toString(), id.value);
      expect(id, equals(id));
    }
    expect(TaskId('same'), isNot(NoteId('same')));
  });

  test('typed IDs reject empty, unsafe, and oversized values', () {
    for (final String value in <String>[
      '',
      '../task',
      'has space',
      'a' * 129,
    ]) {
      expect(() => TaskId(value), throwsFormatException);
    }
  });
}
