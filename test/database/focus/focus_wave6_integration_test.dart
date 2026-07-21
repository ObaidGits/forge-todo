import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/focus/application/focus_commands.dart';
import 'package:forge/features/focus/domain/focus_link.dart';
import 'package:forge/features/focus/domain/focus_mode.dart';
import 'package:forge/features/focus/domain/focus_session.dart';
import 'package:forge/features/focus/domain/focus_session_status.dart';

import 'focus_test_support.dart';

/// Wave 6 risk gate — focus lifecycle integrations over a real Drift store:
/// process death (same boot), an eight-hour long timer, and the now-present
/// habit link existence check.
///
/// Timer truth (wall + monotonic anchors under a boot id) is durable, so a
/// process that dies and reopens over the same database and boot resolves
/// elapsed time from the monotonic clock without fabricating or losing time
/// (R-FOCUS-002, NFR-REL-004). One-open/no-overlap holds across the restart
/// (R-FOCUS-003). Now that the habits schema exists, a focus session may only
/// link to a habit that exists for the profile (R-FOCUS-002/R-GEN-002).
///
/// **Validates: Requirements R-FOCUS-002, R-FOCUS-003, R-FOCUS-005, R-FOCUS-006, NFR-REL-004**
///
/// Evidence: [TEST-DB-FOCUS-WAVE6][MVP][TASK-7.6][R-FOCUS-002,R-FOCUS-003,NFR-REL-004]
void main() {
  late FocusHarness harness;

  setUp(() async {
    harness = await FocusHarness.open(initialUtc: DateTime.utc(2024, 6, 1, 12));
  });

  tearDown(() async {
    await harness.close();
  });

  Future<void> insertHabit(FocusHarness h, String id) async {
    // A minimal current habit row so a habit link can be existence-validated.
    await h.db.customStatement(
      'INSERT INTO habits '
      '(id, profile_id, life_area_id, title, current_schedule_version_id, '
      'status, rank, revision, created_at_utc, updated_at_utc) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, 1, 0, 0)',
      <Object?>[
        id,
        h.profileId.value,
        h.lifeAreaId.value,
        'Meditate',
        's-placeholder',
        'active',
        'm',
      ],
    );
  }

  group('[TEST-DB-FOCUS-PROCESS-DEATH][MVP][TASK-7.6][R-FOCUS-002,NFR-REL-004] '
      'process death preserves durable timer truth', () {
    test('a session survives process death (same boot) and resolves elapsed '
        'from the monotonic clock', () async {
      final String id = await harness.start(
        input: StartFocusSessionInput(
          lifeAreaId: harness.lifeAreaId.value,
          mode: FocusMode.countUp,
        ),
      );

      // Simulate process death and relaunch over the SAME database and the
      // SAME boot id: the OS monotonic clock kept advancing while the process
      // was gone (40 minutes), and the wall clock advanced too.
      final FocusHarness relaunched = await FocusHarness.open(
        database: harness.db,
        freshProfile: false,
        initialUtc: DateTime.utc(2024, 6, 1, 12, 40),
        monotonicInitial: const Duration(minutes: 40),
        idStart: 5000,
      );

      // The open session is still visible after the restart.
      final FocusSession? reopened = await relaunched.reads.openSession(
        relaunched.profileId,
      );
      expect(reopened, isNotNull);
      expect(reopened!.id.value, id);

      relaunched.expectSuccess(
        await relaunched.service.end(
          commandId: relaunched.nextCommandId('e'),
          profileId: relaunched.profileId,
          input: EndFocusSessionInput(sessionId: id),
        ),
      );

      final FocusSession session = (await relaunched.reads.findSession(
        relaunched.profileId,
        FocusSessionId(id),
      ))!;
      expect(session.status, FocusSessionStatus.completed);
      // Same boot ⇒ monotonic is authoritative: 40 minutes, no fabrication.
      expect(session.accumulatedDurationSec, 40 * 60);
      // No open interval survives the completed session.
      expect(
        await relaunched.scalar(
          'SELECT COUNT(*) FROM focus_intervals WHERE profile_id = ? '
          'AND ended_at_utc IS NULL',
          <Object?>[relaunched.profileId.value],
        ),
        0,
      );
    });
  });

  group(
    '[TEST-DB-FOCUS-LONG-TIMER][MVP][TASK-7.6][R-FOCUS-002] long timer',
    () {
      test('an eight-hour count-up session accumulates exactly eight hours '
          'from the monotonic clock', () async {
        final String id = await harness.start(
          input: StartFocusSessionInput(
            lifeAreaId: harness.lifeAreaId.value,
            mode: FocusMode.countUp,
          ),
        );
        harness.clock.advance(const Duration(hours: 8));
        harness.monotonic.advance(const Duration(hours: 8));
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
        expect(session.accumulatedDurationSec, 8 * 60 * 60);
      });
    },
  );

  group('[TEST-DB-FOCUS-HABIT-LINK][MVP][TASK-7.6][R-FOCUS-002] habit link '
      'existence', () {
    test('linking to a missing habit is rejected', () async {
      final Result<CommittedCommandResult> result = await harness.service.start(
        commandId: harness.nextCommandId('missing'),
        profileId: harness.profileId,
        input: StartFocusSessionInput(
          lifeAreaId: harness.lifeAreaId.value,
          mode: FocusMode.countUp,
          link: const FocusLink(
            type: FocusLinkType.habit,
            targetId: 'no-such-habit',
          ),
        ),
      );
      expect(
        (result as Failed<CommittedCommandResult>).failure.code,
        'focus.link_target_not_found',
      );
    });

    test('a link to an existing habit is stored on the session', () async {
      await insertHabit(harness, 'habit-1');
      final String id = await harness.start(
        input: StartFocusSessionInput(
          lifeAreaId: harness.lifeAreaId.value,
          mode: FocusMode.countUp,
          link: const FocusLink(type: FocusLinkType.habit, targetId: 'habit-1'),
        ),
      );
      final FocusSession session = (await harness.reads.findSession(
        harness.profileId,
        FocusSessionId(id),
      ))!;
      expect(
        session.link,
        const FocusLink(type: FocusLinkType.habit, targetId: 'habit-1'),
      );
    });
  });
}
