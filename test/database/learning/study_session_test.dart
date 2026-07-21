import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/core/domain/time_span.dart';
import 'package:forge/features/learning/application/learning_commands.dart';
import 'package:forge/features/learning/domain/learning_policies.dart';
import 'package:forge/features/learning/domain/learning_statistics.dart';
import 'package:forge/features/learning/domain/study_session.dart';
import 'package:forge/features/learning/domain/study_session_event_kind.dart';

import 'learning_test_support.dart';

int _us(DateTime t) => t.microsecondsSinceEpoch;

void main() {
  late LearningHarness harness;

  setUp(() async {
    harness = await LearningHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  Future<String> logSession(
    String rid, {
    required DateTime start,
    required DateTime end,
    String? itemId,
    String? note,
    String? seed,
  }) async {
    final CommittedCommandResult r = harness.expectSuccess(
      await harness.service.logStudySession(
        commandId: harness.nextCommandId(seed),
        profileId: harness.profileId,
        input: LogStudySessionInput(
          resourceId: rid,
          startedAtUtc: _us(start),
          endedAtUtc: _us(end),
          itemId: itemId,
          note: note,
        ),
      ),
    );
    // logical_id is returned in the payload.
    final RegExp re = RegExp('"logical_id":"([^"]+)"');
    return re.firstMatch(r.resultPayload!)!.group(1)!;
  }

  group('Log study session (R-LEARN-002)', () {
    test(
      'logging records a current version-1 session and a logged event',
      () async {
        final String rid = await harness.createResource();
        final String logicalId = await logSession(
          rid,
          start: DateTime.utc(2024, 6, 1, 9),
          end: DateTime.utc(2024, 6, 1, 10),
          note: 'good session',
        );

        final List<StudySession> sessions = await harness.reads
            .currentSessionsOf(harness.profileId, LearningResourceId(rid));
        expect(sessions.length, 1);
        expect(sessions.single.version, 1);
        expect(sessions.single.isCurrent, isTrue);
        expect(sessions.single.durationSec, 3600);
        expect(sessions.single.note, 'good session');

        final List<StudySessionEvent> events = await harness.reads
            .sessionEvents(harness.profileId, logicalId);
        expect(events.length, 1);
        expect(events.single.kind, StudySessionEventKind.logged);
      },
    );

    test('end before start is rejected', () async {
      final String rid = await harness.createResource();
      final Result<CommittedCommandResult> result = await harness.service
          .logStudySession(
            commandId: harness.nextCommandId(),
            profileId: harness.profileId,
            input: LogStudySessionInput(
              resourceId: rid,
              startedAtUtc: _us(DateTime.utc(2024, 6, 1, 10)),
              endedAtUtc: _us(DateTime.utc(2024, 6, 1, 9)),
            ),
          );
      expect(result, isA<Failed<CommittedCommandResult>>());
      expect(
        (result as Failed<CommittedCommandResult>).failure.code,
        'learning.session_end_before_start',
      );
    });
  });

  group('Immutable correction and supersession (R-LEARN-002)', () {
    test(
      'correcting appends a superseding version and preserves the prior facts',
      () async {
        final String rid = await harness.createResource();
        final String logicalId = await logSession(
          rid,
          start: DateTime.utc(2024, 6, 1, 9),
          end: DateTime.utc(2024, 6, 1, 10),
          note: 'original',
        );

        harness.expectSuccess(
          await harness.service.correctStudySession(
            commandId: harness.nextCommandId(),
            profileId: harness.profileId,
            input: CorrectStudySessionInput(
              logicalId: logicalId,
              endedAtUtc: _us(DateTime.utc(2024, 6, 1, 11)),
              note: FieldEdit<String>.set('corrected'),
              reason: 'ran longer',
            ),
          ),
        );

        // Exactly one current version, now version 2 with the corrected facts.
        final List<StudySession> current = await harness.reads
            .currentSessionsOf(harness.profileId, LearningResourceId(rid));
        expect(current.length, 1);
        expect(current.single.version, 2);
        expect(current.single.durationSec, 7200);
        expect(current.single.note, 'corrected');
        expect(current.single.supersedesId, isNotNull);

        // Two physical version rows exist for the logical session; the prior is
        // retained with is_current = 0 and its original facts intact.
        final int totalRows = await harness.scalar(
          'SELECT COUNT(*) FROM study_sessions WHERE logical_id = ?',
          <Object?>[logicalId],
        );
        expect(totalRows, 2);
        final Map<String, Object?>? prior = await harness.firstRow(
          'SELECT duration_sec, note, is_current FROM study_sessions '
          'WHERE logical_id = ? AND version = 1',
          <Object?>[logicalId],
        );
        expect(prior!['duration_sec'], 3600);
        expect(prior['note'], 'original');
        expect(prior['is_current'], 0);

        // The lifecycle log appended a corrected event that supersedes v1.
        final List<StudySessionEvent> events = await harness.reads
            .sessionEvents(harness.profileId, logicalId);
        expect(
          events.map((StudySessionEvent e) => e.kind).toList(),
          <StudySessionEventKind>[
            StudySessionEventKind.logged,
            StudySessionEventKind.corrected,
          ],
        );
        expect(events.last.supersedesId, isNotNull);
      },
    );

    test(
      'at most one current version per logical session (DB invariant)',
      () async {
        final String rid = await harness.createResource();
        final String logicalId = await logSession(
          rid,
          start: DateTime.utc(2024, 6, 1, 9),
          end: DateTime.utc(2024, 6, 1, 10),
        );
        await harness.service.correctStudySession(
          commandId: harness.nextCommandId(),
          profileId: harness.profileId,
          input: CorrectStudySessionInput(
            logicalId: logicalId,
            note: FieldEdit<String>.set('c1'),
          ),
        );
        final int currentCount = await harness.scalar(
          'SELECT COUNT(*) FROM study_sessions '
          'WHERE logical_id = ? AND is_current = 1',
          <Object?>[logicalId],
        );
        expect(currentCount, 1);
      },
    );

    test('correcting an unknown session fails', () async {
      final Result<CommittedCommandResult> result = await harness.service
          .correctStudySession(
            commandId: harness.nextCommandId(),
            profileId: harness.profileId,
            input: const CorrectStudySessionInput(logicalId: 'nope'),
          );
      expect(result, isA<Failed<CommittedCommandResult>>());
      expect(
        (result as Failed<CommittedCommandResult>).failure.code,
        'learning.session_not_found',
      );
    });
  });

  group('Statistics and interval union (R-LEARN-005, R-FOCUS-005)', () {
    test('studied duration unions overlapping current sessions once', () async {
      final String rid = await harness.createResource();
      // 09:00-10:00 and 09:30-10:30 overlap; union is 09:00-10:30 = 5400s.
      await logSession(
        rid,
        start: DateTime.utc(2024, 6, 1, 9),
        end: DateTime.utc(2024, 6, 1, 10),
        seed: 's1',
      );
      await logSession(
        rid,
        start: DateTime.utc(2024, 6, 1, 9, 30),
        end: DateTime.utc(2024, 6, 1, 10, 30),
        seed: 's2',
      );

      final LearningStatistics stats = await harness.reads.statistics(
        harness.profileId,
        rangeStartUtc: _us(DateTime.utc(2024, 6, 1)),
        rangeEndUtc: _us(DateTime.utc(2024, 6, 2)),
      );
      expect(stats.studiedDurationSec, 5400);
      expect(stats.sessionCount, 2);
    });

    test(
      'disjoint sessions sum, and completed items in range are counted',
      () async {
        final String rid = await harness.createResource();
        final String item = await harness.addItem(rid, seed: 'a');
        await logSession(
          rid,
          start: DateTime.utc(2024, 6, 1, 9),
          end: DateTime.utc(2024, 6, 1, 10),
          seed: 's1',
        );
        await logSession(
          rid,
          start: DateTime.utc(2024, 6, 1, 12),
          end: DateTime.utc(2024, 6, 1, 12, 30),
          seed: 's2',
        );
        await harness.service.completeItem(
          commandId: harness.nextCommandId(),
          profileId: harness.profileId,
          itemId: item,
          completedAtUtc: _us(DateTime.utc(2024, 6, 1, 11)),
        );

        final LearningStatistics stats = await harness.reads.statistics(
          harness.profileId,
          rangeStartUtc: _us(DateTime.utc(2024, 6, 1)),
          rangeEndUtc: _us(DateTime.utc(2024, 6, 2)),
        );
        expect(stats.studiedDurationSec, 3600 + 1800);
        expect(stats.completedItems, 1);
      },
    );

    test(
      'a superseded session version is excluded from studied duration',
      () async {
        final String rid = await harness.createResource();
        final String logicalId = await logSession(
          rid,
          start: DateTime.utc(2024, 6, 1, 9),
          end: DateTime.utc(2024, 6, 1, 10),
          seed: 's1',
        );
        // Correct down to 30 minutes; only the current version should count.
        await harness.service.correctStudySession(
          commandId: harness.nextCommandId(),
          profileId: harness.profileId,
          input: CorrectStudySessionInput(
            logicalId: logicalId,
            endedAtUtc: _us(DateTime.utc(2024, 6, 1, 9, 30)),
          ),
        );
        final LearningStatistics stats = await harness.reads.statistics(
          harness.profileId,
          rangeStartUtc: _us(DateTime.utc(2024, 6, 1)),
          rangeEndUtc: _us(DateTime.utc(2024, 6, 2)),
        );
        expect(stats.studiedDurationSec, 1800);
        expect(stats.sessionCount, 1);
      },
    );

    test('study intervals contract clips to the requested range', () async {
      final String rid = await harness.createResource();
      await logSession(
        rid,
        start: DateTime.utc(2024, 6, 1, 8),
        end: DateTime.utc(2024, 6, 1, 12),
        seed: 's1',
      );
      // Query a 1-hour window inside the 4-hour session.
      final List<TimeSpan> intervals = await harness.reads.studyIntervals(
        harness.profileId,
        rangeStartUtc: _us(DateTime.utc(2024, 6, 1, 9)),
        rangeEndUtc: _us(DateTime.utc(2024, 6, 1, 10)),
      );
      expect(intervals.length, 1);
      expect(
        LearningPolicies.unionDuration(intervals) ~/
            StudySession.microsPerSecond,
        3600,
      );
    });

    test('area filter scopes studied duration', () async {
      final LearningHarness h = await LearningHarness.open(secondArea: true);
      try {
        final String rid = await h.createResource(seed: 'r1');
        await h.service.logStudySession(
          commandId: h.nextCommandId('log1'),
          profileId: h.profileId,
          input: LogStudySessionInput(
            resourceId: rid,
            startedAtUtc: _us(DateTime.utc(2024, 6, 1, 9)),
            endedAtUtc: _us(DateTime.utc(2024, 6, 1, 10)),
          ),
        );
        // Filter by a different area yields no studied time.
        final LearningStatistics other = await h.reads.statistics(
          h.profileId,
          rangeStartUtc: _us(DateTime.utc(2024, 6, 1)),
          rangeEndUtc: _us(DateTime.utc(2024, 6, 2)),
          lifeAreaId: LifeAreaId('area-2'),
        );
        expect(other.studiedDurationSec, 0);

        final LearningStatistics own = await h.reads.statistics(
          h.profileId,
          rangeStartUtc: _us(DateTime.utc(2024, 6, 1)),
          rangeEndUtc: _us(DateTime.utc(2024, 6, 2)),
          lifeAreaId: h.lifeAreaId,
        );
        expect(own.studiedDurationSec, 3600);
      } finally {
        await h.close();
      }
    });
  });
}
