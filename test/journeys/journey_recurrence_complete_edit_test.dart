import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_frequency.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_rule.dart';

import 'journey_support.dart';

/// Critical journey 2 (MVP): a recurring task is completed (appending immutable
/// occurrence history and advancing to the next deterministic occurrence) and
/// then edited "this and future" (closing the old schedule version and creating
/// a successor). A kill/reopen proves generated history stays immutable and the
/// successor version persists (R-TASK-005, R-TASK-006, R-TASK-007).
///
/// **Validates: Requirements R-TASK-005, R-TASK-006, R-TASK-007, R-GEN-004,
/// R-GEN-005**
void main() {
  late Directory dir;
  late JourneyApp app;

  RecurrenceRule dailyFrom(String iso, {int interval = 1}) => RecurrenceRule(
    frequency: RecurrenceFrequency.daily,
    start: LocalDate.parse(iso),
    timezoneId: 'Etc/UTC',
    interval: interval,
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('forge-journey-recur-');
    app = await JourneyApp.launch(file: '${dir.path}/forge.db');
  });

  tearDown(() async {
    await app.close();
    await dir.delete(recursive: true);
  });

  test('[TEST-JOURNEY-RECURRENCE-001][MVP][TASK-4.8]'
      '[R-TASK-005,R-TASK-006,R-TASK-007,R-GEN-005] complete then edit '
      'this-and-future preserves immutable history across a restart', () async {
    final String id = await app.quickCapture('Daily standup', seed: 'r');
    await app.setRecurrence(id, dailyFrom('2024-06-10'), seed: 'set');
    expect(await app.scalar('SELECT COUNT(*) FROM recurrence_rules'), 1);

    // Complete the first occurrence: appends immutable history, advances.
    final done = await app.completeOccurrence(id, seed: 'c1');
    expect(done.replayed, isFalse);
    expect(
      await app.scalar(
        "SELECT COUNT(*) FROM task_occurrence_events "
        "WHERE event_kind = 'complete'",
      ),
      1,
    );
    final open = await app.scalar(
      "SELECT COUNT(*) FROM task_occurrences WHERE status = 'open'",
    );
    expect(open, 1);

    // Edit this-and-future: close the old version, create a successor.
    final edited = await app.editRecurrenceThisAndFuture(
      id,
      newRule: dailyFrom('2024-06-11', interval: 2),
      fromKey: LocalDate(2024, 6, 11),
      seed: 'edit',
    );
    expect(edited.resultCode, 'recurrence_split');
    expect(await app.scalar('SELECT COUNT(*) FROM recurrence_rules'), 2);
    expect(
      await app.scalar(
        'SELECT COUNT(*) FROM recurrence_rules '
        'WHERE closed_at_occurrence_key IS NOT NULL',
      ),
      1,
    );

    // Kill and reopen: the immutable completion event and both schedule
    // versions (one closed) must survive exactly.
    await app.restart();

    expect(
      await app.scalar(
        "SELECT COUNT(*) FROM task_occurrence_events "
        "WHERE event_kind = 'complete'",
      ),
      1,
    );
    expect(await app.scalar('SELECT COUNT(*) FROM recurrence_rules'), 2);
    expect(
      await app.scalar(
        'SELECT COUNT(*) FROM recurrence_rules '
        'WHERE closed_at_occurrence_key IS NOT NULL',
      ),
      1,
    );
  });

  test(
    '[TEST-JOURNEY-RECURRENCE-002][MVP][TASK-4.8][R-TASK-006,R-GEN-005] '
    'replaying the same completion command is idempotent after a restart',
    () async {
      final String id = await app.quickCapture('Take vitamins', seed: 'v');
      await app.setRecurrence(id, dailyFrom('2024-06-10'), seed: 'set');

      final first = await app.completeOccurrence(id, seed: 'once');
      expect(first.replayed, isFalse);

      await app.restart();

      // The same command id replays to the stored receipt: no second history
      // event and no duplicated occurrence advance.
      final replay = await app.completeOccurrence(id, seed: 'once');
      expect(replay.replayed, isTrue);
      expect(
        await app.scalar(
          "SELECT COUNT(*) FROM task_occurrence_events "
          "WHERE event_kind = 'complete'",
        ),
        1,
      );
    },
  );
}
