import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/routing/uri_policy.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/core/security/app_lock.dart';
import 'package:forge/features/home/application/inbound_capture_service.dart';
import 'package:forge/features/home/domain/inbound_capture.dart';
import 'package:forge/features/tasks/application/task_command_service.dart';
import 'package:forge/features/tasks/application/task_commands.dart';

/// Unit tests for the inbound quick-capture pipeline (R-SEARCH-004, R-SEC-003,
/// R-SEC-005, R-GEN-005).
///
/// **Validates: Requirements R-SEARCH-004, R-SEC-003, R-SEC-005, R-GEN-005**
void main() {
  const String taskUuid = '01890f3e-7b8a-7cc2-8b34-123456789abc';

  final UriPolicy policy = UriPolicy();
  final InboundCaptureService service = InboundCaptureService(
    uriPolicy: policy,
  );

  ProfileId profile() => ProfileId('profile-1');
  LifeAreaId area() => LifeAreaId('area-1');

  AppLockGate openGate() => AppLockGate(elapsed: () => Duration.zero);
  AppLockGate lockedGate() =>
      AppLockGate(elapsed: () => Duration.zero, configured: true);
  AppLockGate unlockedGate() => lockedGate()..markUnlocked();

  CaptureOwnership ownershipWith(_RecordingCommands commands) =>
      CaptureOwnership(
        profileId: profile(),
        lifeAreaId: area(),
        commands: commands,
      );

  group('URI validation through the centralized policy', () {
    test('accepts a valid desktop protocol argument and captures', () async {
      final _RecordingCommands commands = _RecordingCommands();
      final CaptureOutcome outcome = await service.capture(
        request: const InboundCaptureRequest(
          source: CaptureSource.desktopArgument,
          deliveryId: 'd1',
          uri: 'forge://app/today',
          sharedText: 'Prepare slides',
        ),
        ownership: ownershipWith(commands),
        lock: openGate(),
      );

      expect(outcome, isA<CaptureCommitted>());
      expect(commands.createCount, 1);
    });

    test(
      'rejects a content-like inbound identifier without echoing it',
      () async {
        final _RecordingCommands commands = _RecordingCommands();
        final CaptureOutcome outcome = await service.capture(
          request: const InboundCaptureRequest(
            source: CaptureSource.shareIntent,
            deliveryId: 'd2',
            uri: 'forge://app/notes/private-note-title',
            sharedText: 'anything',
          ),
          ownership: ownershipWith(commands),
          lock: openGate(),
        );

        expect(outcome, isA<CaptureRejected>());
        final CaptureRejected rejected = outcome as CaptureRejected;
        expect(rejected.reason, CaptureRejectionReason.unsupportedInvocation);
        expect(rejected.rejection, UriRejection.invalidIdentifier);
        // Nothing committed and no content surfaced back.
        expect(commands.createCount, 0);
      },
    );

    test('rejects a malformed/oversized protocol argument', () async {
      final _RecordingCommands commands = _RecordingCommands();
      final CaptureOutcome outcome = await service.capture(
        request: InboundCaptureRequest(
          source: CaptureSource.desktopArgument,
          deliveryId: 'd3',
          // Multiple arguments are never a valid single deep link.
          uri: 'forge://app/today extra',
          sharedText: 'x',
        ),
        ownership: ownershipWith(commands),
        lock: openGate(),
      );

      expect(outcome, isA<CaptureRejected>());
      expect(
        (outcome as CaptureRejected).reason,
        CaptureRejectionReason.unsupportedInvocation,
      );
      expect(commands.createCount, 0);
    });

    test('a share intent without a URI still captures its text', () async {
      final _RecordingCommands commands = _RecordingCommands();
      final CaptureOutcome outcome = await service.capture(
        request: const InboundCaptureRequest(
          source: CaptureSource.shareIntent,
          deliveryId: 'd4',
          sharedText: 'Read this article',
        ),
        ownership: ownershipWith(commands),
        lock: openGate(),
      );

      expect(outcome, isA<CaptureCommitted>());
      expect(commands.lastTitle, 'Read this article');
    });

    test('accepts an inbound deep link carrying an opaque id', () async {
      final _RecordingCommands commands = _RecordingCommands();
      final CaptureOutcome outcome = await service.capture(
        request: InboundCaptureRequest(
          source: CaptureSource.shareIntent,
          deliveryId: 'd5',
          uri: 'forge://app/tasks/$taskUuid',
          sharedText: 'Linked capture',
        ),
        ownership: ownershipWith(commands),
        lock: openGate(),
      );

      expect(outcome, isA<CaptureCommitted>());
    });
  });

  group('content validation and sanitization (R-SEC-005 size limits)', () {
    test('rejects missing, empty, and whitespace-only content', () async {
      for (final String? text in <String?>[null, '', '   ', '\n\t ']) {
        final _RecordingCommands commands = _RecordingCommands();
        final CaptureOutcome outcome = await service.capture(
          request: InboundCaptureRequest(
            source: CaptureSource.globalShortcut,
            deliveryId: 'e-$text',
            sharedText: text,
          ),
          ownership: ownershipWith(commands),
          lock: openGate(),
        );
        expect(outcome, isA<CaptureRejected>(), reason: 'text=$text');
        expect(
          (outcome as CaptureRejected).reason,
          CaptureRejectionReason.invalidContent,
        );
        expect(commands.createCount, 0);
      }
    });

    test('rejects content beyond the size bound', () async {
      final _RecordingCommands commands = _RecordingCommands();
      final CaptureOutcome outcome = await service.capture(
        request: InboundCaptureRequest(
          source: CaptureSource.shareIntent,
          deliveryId: 'big',
          sharedText: 'a' * 513,
        ),
        ownership: ownershipWith(commands),
        lock: openGate(),
      );
      expect(outcome, isA<CaptureRejected>());
      expect(
        (outcome as CaptureRejected).reason,
        CaptureRejectionReason.invalidContent,
      );
    });

    test('strips control characters and collapses whitespace', () async {
      final _RecordingCommands commands = _RecordingCommands();
      final CaptureOutcome outcome = await service.capture(
        request: const InboundCaptureRequest(
          source: CaptureSource.shareIntent,
          deliveryId: 'ctrl',
          sharedText: '  Buy\tmilk\nand\u0007eggs  ',
        ),
        ownership: ownershipWith(commands),
        lock: openGate(),
      );
      expect(outcome, isA<CaptureCommitted>());
      expect(commands.lastTitle, 'Buy milk and eggs');
    });
  });

  group('ownership (R-GEN-002)', () {
    test('refuses when no profile is active', () async {
      final _RecordingCommands commands = _RecordingCommands();
      final CaptureOutcome outcome = await service.capture(
        request: const InboundCaptureRequest(
          source: CaptureSource.shareIntent,
          deliveryId: 'o1',
          sharedText: 'Task',
        ),
        ownership: CaptureOwnership(
          profileId: null,
          lifeAreaId: area(),
          commands: commands,
        ),
        lock: openGate(),
      );
      expect(outcome, isA<CaptureRejected>());
      expect(
        (outcome as CaptureRejected).reason,
        CaptureRejectionReason.ownershipUnavailable,
      );
      expect(commands.createCount, 0);
    });

    test('refuses when no Life Area or command surface is available', () async {
      final _RecordingCommands commands = _RecordingCommands();
      final CaptureOutcome noArea = await service.capture(
        request: const InboundCaptureRequest(
          source: CaptureSource.shareIntent,
          deliveryId: 'o2',
          sharedText: 'Task',
        ),
        ownership: CaptureOwnership(profileId: profile(), commands: commands),
        lock: openGate(),
      );
      final CaptureOutcome noCommands = await service.capture(
        request: const InboundCaptureRequest(
          source: CaptureSource.shareIntent,
          deliveryId: 'o3',
          sharedText: 'Task',
        ),
        ownership: CaptureOwnership(profileId: profile(), lifeAreaId: area()),
        lock: openGate(),
      );
      expect(
        (noArea as CaptureRejected).reason,
        CaptureRejectionReason.ownershipUnavailable,
      );
      expect(
        (noCommands as CaptureRejected).reason,
        CaptureRejectionReason.ownershipUnavailable,
      );
    });
  });

  group('lock/privacy gating (R-SEC-003, R-SEC-005)', () {
    test(
      'withholds capture into a locked surface and commits nothing',
      () async {
        final _RecordingCommands commands = _RecordingCommands();
        final CaptureOutcome outcome = await service.capture(
          request: const InboundCaptureRequest(
            source: CaptureSource.shareIntent,
            deliveryId: 'lock1',
            sharedText: 'Sensitive task',
          ),
          ownership: ownershipWith(commands),
          lock: lockedGate(),
        );
        expect(outcome, isA<CaptureGated>());
        // Nothing committed; content never reaches the command bus while locked.
        expect(commands.createCount, 0);
      },
    );

    test('commits once the session is unlocked', () async {
      final _RecordingCommands commands = _RecordingCommands();
      final CaptureOutcome outcome = await service.capture(
        request: const InboundCaptureRequest(
          source: CaptureSource.shareIntent,
          deliveryId: 'lock2',
          sharedText: 'Sensitive task',
        ),
        ownership: ownershipWith(commands),
        lock: unlockedGate(),
      );
      expect(outcome, isA<CaptureCommitted>());
      expect(commands.createCount, 1);
    });

    test('an unconfigured gate is always open', () async {
      final _RecordingCommands commands = _RecordingCommands();
      final CaptureOutcome outcome = await service.capture(
        request: const InboundCaptureRequest(
          source: CaptureSource.globalShortcut,
          deliveryId: 'lock3',
          sharedText: 'Task',
        ),
        ownership: ownershipWith(commands),
        lock: openGate(),
      );
      expect(outcome, isA<CaptureCommitted>());
    });
  });

  group('commit failures and command-id derivation (R-GEN-005)', () {
    test('maps a command-bus failure to a refusal', () async {
      final _RecordingCommands commands = _RecordingCommands(
        failWith: const Failure(
          kind: FailureKind.storage,
          code: 'db.write_failed',
          safeMessageKey: 'error.storage',
          retryable: true,
        ),
      );
      final CaptureOutcome outcome = await service.capture(
        request: const InboundCaptureRequest(
          source: CaptureSource.shareIntent,
          deliveryId: 'f1',
          sharedText: 'Task',
        ),
        ownership: ownershipWith(commands),
        lock: openGate(),
      );
      expect(outcome, isA<CaptureRejected>());
      final CaptureRejected rejected = outcome as CaptureRejected;
      expect(rejected.reason, CaptureRejectionReason.commitFailed);
      expect(rejected.failure?.code, 'db.write_failed');
    });

    test('derives a stable command id per delivery and namespaces sources', () {
      final CommandId a = defaultCaptureCommandId(
        CaptureSource.shareIntent,
        'delivery-42',
      );
      final CommandId b = defaultCaptureCommandId(
        CaptureSource.shareIntent,
        'delivery-42',
      );
      final CommandId other = defaultCaptureCommandId(
        CaptureSource.shareIntent,
        'delivery-99',
      );
      final CommandId sameIdOtherSource = defaultCaptureCommandId(
        CaptureSource.desktopArgument,
        'delivery-42',
      );

      expect(a.value, b.value);
      expect(a.value, isNot(other.value));
      expect(a.value, isNot(sameIdOtherSource.value));
      // The derived id satisfies the CommandId grammar.
      expect(() => CommandId(a.value), returnsNormally);
    });

    test(
      'the same delivery maps to the same command id used for capture',
      () async {
        final _RecordingCommands commands = _RecordingCommands();
        await service.capture(
          request: const InboundCaptureRequest(
            source: CaptureSource.shareIntent,
            deliveryId: 'repeat',
            sharedText: 'Task',
          ),
          ownership: ownershipWith(commands),
          lock: openGate(),
        );
        await service.capture(
          request: const InboundCaptureRequest(
            source: CaptureSource.shareIntent,
            deliveryId: 'repeat',
            sharedText: 'Task',
          ),
          ownership: ownershipWith(commands),
          lock: openGate(),
        );
        expect(commands.commandIds.length, 2);
        expect(commands.commandIds.first.value, commands.commandIds.last.value);
      },
    );
  });
}

/// A fake [TaskCommandService] that records create calls. It does not
/// deduplicate — the real command bus does — so idempotent re-delivery is
/// proven against the real service in the database-backed suite.
final class _RecordingCommands implements TaskCommandService {
  _RecordingCommands({this.failWith});

  final Failure? failWith;
  int createCount = 0;
  String? lastTitle;
  final List<CommandId> commandIds = <CommandId>[];

  @override
  Future<Result<CommittedCommandResult>> create({
    required CommandId commandId,
    required ProfileId profileId,
    required CreateTaskInput input,
  }) async {
    createCount += 1;
    lastTitle = input.title;
    commandIds.add(commandId);
    if (failWith != null) {
      return Failed<CommittedCommandResult>(failWith!);
    }
    return Success<CommittedCommandResult>(
      CommittedCommandResult(
        commandId: commandId,
        resultCode: 'created',
        payloadVersion: 1,
        commitSeq: createCount,
        replayed: false,
        resultPayload: '{"id":"task-$createCount"}',
      ),
    );
  }

  @override
  Future<Result<CommittedCommandResult>> update({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
    required UpdateTaskInput input,
  }) => throw UnimplementedError();

  @override
  Future<Result<CommittedCommandResult>> complete({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
  }) => throw UnimplementedError();

  @override
  Future<Result<CommittedCommandResult>> reopen({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
  }) => throw UnimplementedError();

  @override
  Future<Result<CommittedCommandResult>> cancel({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
  }) => throw UnimplementedError();

  @override
  Future<Result<CommittedCommandResult>> move({
    required CommandId commandId,
    required ProfileId profileId,
    required TaskId taskId,
    required MoveTaskInput input,
  }) => throw UnimplementedError();

  @override
  Future<Result<CommittedCommandResult>> completeMany({
    required CommandId commandId,
    required ProfileId profileId,
    required List<TaskId> taskIds,
  }) => throw UnimplementedError();

  @override
  Future<Result<CommittedCommandResult>> cancelMany({
    required CommandId commandId,
    required ProfileId profileId,
    required List<TaskId> taskIds,
  }) => throw UnimplementedError();
}
