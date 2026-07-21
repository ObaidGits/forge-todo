import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/focus/application/focus_commands.dart';
import 'package:forge/features/focus/domain/focus_event.dart';
import 'package:forge/features/focus/domain/focus_event_kind.dart';
import 'package:forge/features/focus/domain/focus_interval.dart';
import 'package:forge/features/focus/domain/focus_interval_kind.dart';
import 'package:forge/features/focus/domain/focus_link.dart';
import 'package:forge/features/focus/domain/focus_mode.dart';
import 'package:forge/features/focus/domain/focus_preset.dart';
import 'package:forge/features/focus/domain/focus_session.dart';
import 'package:forge/features/focus/domain/focus_session_status.dart';

import 'focus_test_support.dart';

void main() {
  late FocusHarness harness;

  setUp(() async {
    harness = await FocusHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  /// Advances both the wall and monotonic clocks by [d] (same boot).
  void tick(FocusHarness h, Duration d) {
    h.clock.advance(d);
    h.monotonic.advance(d);
  }

  group(
    '[TEST-DB-FOCUS-START][MVP][TASK-7.3][R-FOCUS-001,R-FOCUS-004] start',
    () {
      test('a count-up session persists anchored truth and an open work '
          'interval', () async {
        final String id = await harness.start(
          input: StartFocusSessionInput(
            lifeAreaId: harness.lifeAreaId.value,
            mode: FocusMode.countUp,
          ),
        );
        final FocusSession? session = await harness.reads.findSession(
          harness.profileId,
          FocusSessionId(id),
        );
        expect(session, isNotNull);
        expect(session!.mode, FocusMode.countUp);
        expect(session.plannedDurationSec, isNull);
        expect(session.status, FocusSessionStatus.running);
        expect(session.bootSessionId, 'boot-1');
        expect(session.accumulatedDurationSec, 0);

        final List<FocusInterval> intervals = await harness.reads.intervals(
          harness.profileId,
          FocusSessionId(id),
        );
        expect(intervals.length, 1);
        expect(intervals.single.kind, FocusIntervalKind.work);
        expect(intervals.single.isOpen, isTrue);

        final List<FocusEvent> events = await harness.reads.events(
          harness.profileId,
          FocusSessionId(id),
        );
        expect(events.single.kind, FocusEventKind.started);
      });

      test('the Deep Work preset starts an interval session (a preset, not a '
          'separate model)', () async {
        final String id = await harness.start(
          input: StartFocusSessionInput(
            lifeAreaId: harness.lifeAreaId.value,
            preset: FocusPreset.deepWork,
          ),
        );
        final FocusSession session = (await harness.reads.findSession(
          harness.profileId,
          FocusSessionId(id),
        ))!;
        expect(session.mode, FocusMode.interval);
        expect(session.plannedDurationSec, 90 * 60);
        expect(session.preset, 'deep_work');
      });

      test('only one open session is allowed per profile', () async {
        await harness.start(
          input: StartFocusSessionInput(
            lifeAreaId: harness.lifeAreaId.value,
            mode: FocusMode.countUp,
          ),
          seed: 'first',
        );
        final Result<CommittedCommandResult> second = await harness.service
            .start(
              commandId: harness.nextCommandId('second'),
              profileId: harness.profileId,
              input: StartFocusSessionInput(
                lifeAreaId: harness.lifeAreaId.value,
                mode: FocusMode.countUp,
              ),
            );
        expect(second, isA<Failed<CommittedCommandResult>>());
        expect(
          (second as Failed<CommittedCommandResult>).failure.code,
          'focus.session_already_open',
        );
      });
    },
  );

  group('[TEST-DB-FOCUS-LINK][MVP][TASK-7.3][R-FOCUS-001] entity links', () {
    test('linking to a missing target is rejected', () async {
      final Result<CommittedCommandResult> result = await harness.service.start(
        commandId: harness.nextCommandId(),
        profileId: harness.profileId,
        input: StartFocusSessionInput(
          lifeAreaId: harness.lifeAreaId.value,
          mode: FocusMode.countUp,
          link: const FocusLink(type: FocusLinkType.task, targetId: 'nope'),
        ),
      );
      expect(
        (result as Failed<CommittedCommandResult>).failure.code,
        'focus.link_target_not_found',
      );
    });

    test('a link to an existing task is stored on the session', () async {
      // Insert a minimal linkable task under the same profile/area.
      await harness.db.customStatement(
        'INSERT INTO tasks (id, profile_id, life_area_id, title, status, '
        'priority, rank, revision, created_at_utc, updated_at_utc) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          'task-1',
          harness.profileId.value,
          harness.lifeAreaId.value,
          'Write report',
          'open',
          'none',
          'm',
          1,
          0,
          0,
        ],
      );
      final String id = await harness.start(
        input: StartFocusSessionInput(
          lifeAreaId: harness.lifeAreaId.value,
          mode: FocusMode.countUp,
          link: const FocusLink(type: FocusLinkType.task, targetId: 'task-1'),
        ),
      );
      final FocusSession session = (await harness.reads.findSession(
        harness.profileId,
        FocusSessionId(id),
      ))!;
      expect(
        session.link,
        const FocusLink(type: FocusLinkType.task, targetId: 'task-1'),
      );
    });
  });

  group('[TEST-DB-FOCUS-LIFECYCLE][MVP][TASK-7.3][R-FOCUS-002,R-FOCUS-003] '
      'pause/resume/end append immutable events and intervals', () {
    test('a start-pause-resume-end cycle accumulates work by the monotonic '
        'clock and leaves an append-only event log', () async {
      final String id = await harness.start(
        input: StartFocusSessionInput(
          lifeAreaId: harness.lifeAreaId.value,
          mode: FocusMode.countUp,
        ),
      );
      // Work 25 minutes, pause.
      tick(harness, const Duration(minutes: 25));
      harness.expectSuccess(
        await harness.service.pause(
          commandId: harness.nextCommandId('p'),
          profileId: harness.profileId,
          input: PauseFocusSessionInput(sessionId: id),
        ),
      );
      // Pause for 5 minutes (does not accumulate work), then resume.
      tick(harness, const Duration(minutes: 5));
      harness.expectSuccess(
        await harness.service.resume(
          commandId: harness.nextCommandId('r'),
          profileId: harness.profileId,
          input: ResumeFocusSessionInput(sessionId: id),
        ),
      );
      // Work 10 more minutes, end.
      tick(harness, const Duration(minutes: 10));
      harness.expectSuccess(
        await harness.service.end(
          commandId: harness.nextCommandId('e'),
          profileId: harness.profileId,
          input: EndFocusSessionInput(sessionId: id),
        ),
      );

      final FocusSession session = (await harness.reads.findSession(
        harness.profileId,
        FocusSessionId(id),
      ))!;
      expect(session.status, FocusSessionStatus.completed);
      // 25 + 10 minutes of work; the 5-minute pause is excluded.
      expect(session.accumulatedDurationSec, 35 * 60);
      expect(session.endedAtUtc, isNotNull);

      final List<FocusEvent> events = await harness.reads.events(
        harness.profileId,
        FocusSessionId(id),
      );
      expect(events.map((FocusEvent e) => e.kind).toList(), <FocusEventKind>[
        FocusEventKind.started,
        FocusEventKind.paused,
        FocusEventKind.resumed,
        FocusEventKind.ended,
      ]);

      // Intervals: two work segments and one pause, all closed, none open.
      final List<FocusInterval> intervals = await harness.reads.intervals(
        harness.profileId,
        FocusSessionId(id),
      );
      expect(intervals.length, 3);
      expect(intervals.every((FocusInterval i) => !i.isOpen), isTrue);
      expect(
        intervals
            .where((FocusInterval i) => i.kind == FocusIntervalKind.work)
            .length,
        2,
      );
      expect(
        intervals
            .where((FocusInterval i) => i.kind == FocusIntervalKind.pause)
            .length,
        1,
      );
      // No open interval remains for the profile.
      expect(
        await harness.scalar(
          'SELECT COUNT(*) FROM focus_intervals WHERE profile_id = ? '
          'AND ended_at_utc IS NULL',
          <Object?>[harness.profileId.value],
        ),
        0,
      );
    });

    test('pausing a session that is not running is rejected', () async {
      final String id = await harness.start(
        input: StartFocusSessionInput(
          lifeAreaId: harness.lifeAreaId.value,
          mode: FocusMode.countUp,
        ),
      );
      harness.expectSuccess(
        await harness.service.pause(
          commandId: harness.nextCommandId('p1'),
          profileId: harness.profileId,
          input: PauseFocusSessionInput(sessionId: id),
        ),
      );
      final Result<CommittedCommandResult> again = await harness.service.pause(
        commandId: harness.nextCommandId('p2'),
        profileId: harness.profileId,
        input: PauseFocusSessionInput(sessionId: id),
      );
      expect(
        (again as Failed<CommittedCommandResult>).failure.code,
        'focus.not_running',
      );
    });
  });

  group('[TEST-DB-FOCUS-CORRECT][MVP][TASK-7.3][R-FOCUS-003,R-FOCUS-005] '
      'corrections append audit records without rewriting history', () {
    test('correcting the duration appends a corrected event and keeps the '
        'prior events intact', () async {
      final String id = await harness.start(
        input: StartFocusSessionInput(
          lifeAreaId: harness.lifeAreaId.value,
          mode: FocusMode.countUp,
        ),
      );
      tick(harness, const Duration(minutes: 30));
      harness.expectSuccess(
        await harness.service.end(
          commandId: harness.nextCommandId('e'),
          profileId: harness.profileId,
          input: EndFocusSessionInput(sessionId: id),
        ),
      );

      final int eventsBefore = await harness.scalar(
        'SELECT COUNT(*) FROM focus_events WHERE session_id = ?',
        <Object?>[id],
      );

      harness.expectSuccess(
        await harness.service.correct(
          commandId: harness.nextCommandId('c'),
          profileId: harness.profileId,
          input: CorrectFocusSessionInput(
            sessionId: id,
            correctedDurationSec: 20 * 60,
            reason: 'forgot to pause',
          ),
        ),
      );

      final FocusSession session = (await harness.reads.findSession(
        harness.profileId,
        FocusSessionId(id),
      ))!;
      // The visible projection reflects the correction.
      expect(session.accumulatedDurationSec, 20 * 60);

      // A corrected event was appended; nothing was removed.
      final List<FocusEvent> events = await harness.reads.events(
        harness.profileId,
        FocusSessionId(id),
      );
      expect(events.length, eventsBefore + 1);
      expect(events.last.kind, FocusEventKind.corrected);
      // The original started/ended events are still present, unmodified.
      expect(events.first.kind, FocusEventKind.started);
      expect(
        events.any((FocusEvent e) => e.kind == FocusEventKind.ended),
        isTrue,
      );
    });

    test('a negative correction is rejected', () async {
      final String id = await harness.start(
        input: StartFocusSessionInput(
          lifeAreaId: harness.lifeAreaId.value,
          mode: FocusMode.countUp,
        ),
      );
      final Result<CommittedCommandResult> result = await harness.service
          .correct(
            commandId: harness.nextCommandId('c'),
            profileId: harness.profileId,
            input: CorrectFocusSessionInput(
              sessionId: id,
              correctedDurationSec: -1,
            ),
          );
      expect(
        (result as Failed<CommittedCommandResult>).failure.code,
        'focus.invalid_correction',
      );
    });
  });

  group('[TEST-DB-FOCUS-CONSTRAINTS][MVP][TASK-7.3][R-FOCUS-003] database '
      'invariants', () {
    test('a second open interval for the profile is rejected by the unique '
        'index', () async {
      final String id = await harness.start(
        input: StartFocusSessionInput(
          lifeAreaId: harness.lifeAreaId.value,
          mode: FocusMode.countUp,
        ),
      );
      // The session already has one open work interval. A second open interval
      // for the same profile violates ux_focus_intervals_open.
      expect(
        () => harness.db.customStatement(
          'INSERT INTO focus_intervals (id, profile_id, session_id, '
          'interval_kind, started_at_utc, boot_session_id, created_at_utc) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            'iv-x',
            harness.profileId.value,
            id,
            'work',
            1,
            'boot-1',
            1,
          ],
        ),
        throwsA(anything),
      );
    });

    test('an interval session without a planned duration is rejected', () async {
      expect(
        () => harness.db.customStatement(
          'INSERT INTO focus_sessions (id, profile_id, life_area_id, mode, '
          'status, wall_anchor_utc, monotonic_anchor_micros, boot_session_id, '
          'accumulated_duration_sec, started_at_utc, created_at_utc, '
          'updated_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            'fs-bad',
            harness.profileId.value,
            harness.lifeAreaId.value,
            'interval',
            'running',
            0,
            0,
            'boot-1',
            0,
            0,
            0,
            0,
          ],
        ),
        throwsA(anything),
      );
    });
  });

  group('[TEST-DB-FOCUS-UNION][MVP][TASK-7.3][R-FOCUS-005] combined focus '
      'duration unions overlapping work', () {
    test(
      'overlapping work intervals across sessions are counted once',
      () async {
        // Session 1: 12:00-12:30 work.
        final String s1 = await harness.start(
          input: StartFocusSessionInput(
            lifeAreaId: harness.lifeAreaId.value,
            mode: FocusMode.countUp,
          ),
          seed: 's1',
        );
        tick(harness, const Duration(minutes: 30));
        harness.expectSuccess(
          await harness.service.end(
            commandId: harness.nextCommandId('e1'),
            profileId: harness.profileId,
            input: EndFocusSessionInput(sessionId: s1),
          ),
        );

        // Rewind the wall clock so session 2 overlaps session 1 by 10 minutes:
        // session 2 covers 12:20-12:50.
        harness.clock.setUtc(DateTime.utc(2024, 6, 1, 12, 20));
        final String s2 = await harness.start(
          input: StartFocusSessionInput(
            lifeAreaId: harness.lifeAreaId.value,
            mode: FocusMode.countUp,
          ),
          seed: 's2',
        );
        tick(harness, const Duration(minutes: 30));
        harness.expectSuccess(
          await harness.service.end(
            commandId: harness.nextCommandId('e2'),
            profileId: harness.profileId,
            input: EndFocusSessionInput(sessionId: s2),
          ),
        );

        // Union of 12:00-12:30 and 12:20-12:50 = 12:00-12:50 = 3000s, not 3600s.
        final int union = await harness.reads.focusDurationSec(
          harness.profileId,
          rangeStartUtc: DateTime.utc(2024, 6, 1, 11).microsecondsSinceEpoch,
          rangeEndUtc: DateTime.utc(2024, 6, 1, 13).microsecondsSinceEpoch,
        );
        expect(union, 50 * 60);
      },
    );
  });

  group('[TEST-DB-FOCUS-REBOOT][MVP][TASK-7.3][R-FOCUS-002] reboot / wall-clock '
      'discontinuity reconciliation', () {
    test('ending a session started under a prior boot falls back to bounded '
        'wall reconciliation', () async {
      // Session starts under boot-1 at 12:00.
      final String id = await harness.start(
        input: StartFocusSessionInput(
          lifeAreaId: harness.lifeAreaId.value,
          mode: FocusMode.countUp,
        ),
      );

      // Simulate a reboot: reopen the whole stack over the SAME database with a
      // new boot id and a wall clock advanced to 12:40 (40 minutes later).
      final FocusHarness rebooted = await FocusHarness.open(
        database: harness.db,
        freshProfile: false,
        bootId: 'boot-2',
        initialUtc: DateTime.utc(2024, 6, 1, 12, 40),
        idStart: 5000,
      );

      rebooted.expectSuccess(
        await rebooted.service.end(
          commandId: rebooted.nextCommandId('e'),
          profileId: rebooted.profileId,
          input: EndFocusSessionInput(sessionId: id),
        ),
      );

      final FocusSession session = (await rebooted.reads.findSession(
        rebooted.profileId,
        FocusSessionId(id),
      ))!;
      expect(session.status, FocusSessionStatus.completed);
      // The monotonic anchor from boot-1 is meaningless after the reboot, so
      // the 40-minute segment is reconciled from the wall clock (R-FOCUS-002).
      expect(session.accumulatedDurationSec, 40 * 60);
    });

    test(
      'a backwards wall clock after reboot records no fabricated time',
      () async {
        final String id = await harness.start(
          input: StartFocusSessionInput(
            lifeAreaId: harness.lifeAreaId.value,
            mode: FocusMode.countUp,
          ),
        );
        // Reboot with the wall clock moved BACKWARDS relative to the anchor.
        final FocusHarness rebooted = await FocusHarness.open(
          database: harness.db,
          freshProfile: false,
          bootId: 'boot-2',
          initialUtc: DateTime.utc(2024, 6, 1, 11, 30),
          idStart: 5000,
        );
        rebooted.expectSuccess(
          await rebooted.service.end(
            commandId: rebooted.nextCommandId('e'),
            profileId: rebooted.profileId,
            input: EndFocusSessionInput(sessionId: id),
          ),
        );
        final FocusSession session = (await rebooted.reads.findSession(
          rebooted.profileId,
          FocusSessionId(id),
        ))!;
        // Ambiguous → the lower bound (zero) is recorded, never a negative value.
        expect(session.accumulatedDurationSec, 0);
      },
    );
  });
}
