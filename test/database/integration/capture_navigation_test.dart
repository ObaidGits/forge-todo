import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/routing/canonical_route.dart';
import 'package:forge/app/routing/uri_policy.dart';
import 'package:forge/core/security/app_lock.dart';
import 'package:forge/features/home/application/inbound_capture_service.dart';
import 'package:forge/features/home/domain/inbound_capture.dart';
import 'package:forge/features/planner/domain/planning_reference_type.dart';

import 'notes_integration_support.dart';

/// Real Drift-backed integration proof that quick capture reaches both a task
/// and a canonical note, that every captured record resolves to a canonical
/// route, and that planner-owned periods and their references are reachable
/// (R-SEARCH-004, R-SEARCH-002, R-PLAN-002, R-PLAN-005).
///
/// **Validates: Requirements R-SEARCH-004, R-PLAN-002**
void main() {
  late NotesIntegrationHarness h;
  late InboundCaptureService service;

  setUp(() async {
    h = await NotesIntegrationHarness.open();
    service = InboundCaptureService(uriPolicy: UriPolicy());
  });

  tearDown(() async {
    await h.close();
  });

  AppLockGate unlocked() =>
      AppLockGate(elapsed: () => Duration.zero, configured: true)
        ..markUnlocked();

  CaptureOwnership ownership() => CaptureOwnership(
    profileId: h.profileId,
    lifeAreaId: h.lifeAreaId,
    commands: h.tasks,
    noteCommands: h.notes,
  );

  test('a task-intent capture commits and resolves to a task route', () async {
    final CaptureOutcome outcome = await service.capture(
      request: const InboundCaptureRequest(
        source: CaptureSource.shareIntent,
        deliveryId: 'share-task-1',
        sharedText: 'Call the dentist',
      ),
      ownership: ownership(),
      lock: unlocked(),
    );

    final CaptureCommitted committed = outcome as CaptureCommitted;
    expect(committed.entityType, 'task');
    expect(committed.entityId, isNotNull);
    expect(await h.scalar('SELECT COUNT(*) FROM tasks'), 1);

    // The captured content is reachable via its canonical route.
    final String? route = CanonicalRoute.forEntity(
      committed.entityType,
      committed.entityId!,
    );
    expect(route, '/tasks/${committed.entityId}');
    // And that route is one the app router/UriPolicy accepts.
    expect(UriPolicy().validateRouteLocation(route!), isNull);
  });

  test('a note-intent capture commits into a canonical note', () async {
    final CaptureOutcome outcome = await service.capture(
      request: const InboundCaptureRequest(
        source: CaptureSource.shareIntent,
        deliveryId: 'share-note-1',
        sharedText: 'Idea: local-first sync notes',
        intent: CaptureIntentKind.note,
      ),
      ownership: ownership(),
      lock: unlocked(),
    );

    final CaptureCommitted committed = outcome as CaptureCommitted;
    expect(committed.entityType, 'note');
    expect(committed.entityId, isNotNull);
    // Captured into the single canonical note system, not a task.
    expect(await h.scalar('SELECT COUNT(*) FROM notes'), 1);
    expect(await h.scalar('SELECT COUNT(*) FROM tasks'), 0);

    final String? route = CanonicalRoute.forEntity(
      committed.entityType,
      committed.entityId!,
    );
    expect(route, '/notes/${committed.entityId}');
    expect(UriPolicy().validateRouteLocation(route!), isNull);
  });

  test('a note-intent capture is refused when notes are unavailable', () async {
    final CaptureOutcome outcome = await service.capture(
      request: const InboundCaptureRequest(
        source: CaptureSource.shareIntent,
        deliveryId: 'share-note-2',
        sharedText: 'Orphan note',
        intent: CaptureIntentKind.note,
      ),
      // Task command present, note command absent.
      ownership: CaptureOwnership(
        profileId: h.profileId,
        lifeAreaId: h.lifeAreaId,
        commands: h.tasks,
      ),
      lock: unlocked(),
    );
    expect(
      (outcome as CaptureRejected).reason,
      CaptureRejectionReason.ownershipUnavailable,
    );
    expect(await h.scalar('SELECT COUNT(*) FROM notes'), 0);
  });

  test(
    'a re-delivered note capture replays without a duplicate note',
    () async {
      Future<CaptureOutcome> deliver() => service.capture(
        request: const InboundCaptureRequest(
          source: CaptureSource.shareIntent,
          deliveryId: 'share-note-dup',
          sharedText: 'Recurring idea',
          intent: CaptureIntentKind.note,
        ),
        ownership: ownership(),
        lock: unlocked(),
      );

      final CaptureCommitted first = await deliver() as CaptureCommitted;
      final CaptureCommitted second = await deliver() as CaptureCommitted;
      expect(first.replayed, isFalse);
      expect(second.replayed, isTrue);
      expect(second.entityId, first.entityId);
      expect(await h.scalar('SELECT COUNT(*) FROM notes'), 1);
    },
  );

  test(
    'planner-owned periods and references resolve to canonical routes',
    () async {
      final String periodId = await h.createPlanningPeriod(
        '2024-06-01',
        seed: 'period',
      );
      // The planning period itself is reachable.
      final String? periodRoute = CanonicalRoute.planningPeriod(periodId);
      expect(periodRoute, '/planner/$periodId');
      expect(UriPolicy().validateRouteLocation(periodRoute!), isNull);

      // A planned task reference and a planned note reference are reachable.
      final String taskId = await h.createTask('Prep review', seed: 'ref-task');
      final String noteId = await h.createNote(
        'Review notes',
        seed: 'ref-note',
      );
      await h.addPlanningReference(
        periodId: periodId,
        type: PlanningReferenceType.task,
        entityId: taskId,
        seed: 'add-task',
      );
      await h.addPlanningReference(
        periodId: periodId,
        type: PlanningReferenceType.note,
        entityId: noteId,
        seed: 'add-note',
      );

      expect(
        CanonicalRoute.forEntity(PlanningReferenceType.task.wire, taskId),
        '/tasks/$taskId',
      );
      expect(
        CanonicalRoute.forEntity(PlanningReferenceType.note.wire, noteId),
        '/notes/$noteId',
      );
    },
  );
}
