/// The default [WidgetBridge] implementation (R-WIDGET-002/003/004).
///
/// `publish` persists the redacted, versioned snapshot to the local-only store
/// and pushes it to the native container; both are local-only side effects that
/// never touch the encrypted database or the outbox.
///
/// `execute` is the spoof-resistant, idempotent action path:
///
///   1. verify the untrusted intent (signature, profile binding, freshness);
///   2. route the verified command to the owning feature's durable command
///      service, which runs through the command bus and returns a committed
///      receipt keyed by a command id derived from the intent id;
///   3. a double-tap / re-delivered intent therefore returns the SAME committed
///      receipt and applies no duplicate effect (R-WIDGET-003, R-GEN-005).
///
/// Both paths are bounded by [hostTimeout] so a slow or unavailable bridge
/// fails safe instead of hanging the caller (NFR-REL-004 stale/partial-failure
/// obligation): a publish that cannot reach the native container is dropped
/// after retaining the snapshot in the local store, and an action whose
/// handler does not settle in time returns a retryable
/// [FailureKind.unavailableCapability]. Because the derived command id makes
/// the action idempotent, a retry after a timeout replays the same committed
/// receipt (if the slow handler did commit) or commits exactly once, never
/// producing a duplicate effect.
library;

import 'dart:async';

import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/widgets/application/widget_bridge.dart';
import 'package:forge/features/widgets/application/widget_intent_verifier.dart';
import 'package:forge/features/widgets/domain/widget_intent.dart';
import 'package:forge/features/widgets/domain/widget_snapshot.dart';
import 'package:forge/features/widgets/domain/widget_snapshot_repository.dart';

final class ForgeWidgetBridge implements WidgetBridge {
  const ForgeWidgetBridge({
    required this.verifier,
    required this.handlers,
    required this.channel,
    required this.snapshots,
    this.hostTimeout = const Duration(seconds: 5),
  });

  final WidgetIntentVerifier verifier;

  /// Feature command handlers, tried in order until one supports the action.
  final List<WidgetCommandHandler> handlers;

  final WidgetHostChannel channel;
  final WidgetSnapshotRepository snapshots;

  /// Upper bound on any single native-container interaction. A publish or
  /// action that does not settle within this window fails safe rather than
  /// blocking the caller on an unavailable bridge.
  final Duration hostTimeout;

  @override
  Future<void> publish(WidgetSnapshot snapshot) async {
    // Persist locally first so the container has a durable source to fall back
    // to, then push to the native host. Both are local-only. A slow/unavailable
    // native host must never block or lose the publish: the local store keeps
    // the snapshot for the next reconcile, so the push is bounded and its
    // failure is swallowed.
    await snapshots.save(snapshot);
    try {
      await channel.publish(snapshot).timeout(hostTimeout);
    } on TimeoutException {
      // Fail safe: the snapshot is already durable locally; the container will
      // reconcile on the next successful publish.
    } on Object {
      // A native channel error is non-fatal for a local-only publish.
    }
  }

  @override
  Future<Result<CommittedCommandResult>> execute(WidgetIntent intent) async {
    final Result<VerifiedWidgetCommand> verified = verifier.verify(intent);
    return switch (verified) {
      Failed<VerifiedWidgetCommand>(failure: final Failure failure) =>
        Failed<CommittedCommandResult>(failure),
      Success<VerifiedWidgetCommand>(
        value: final VerifiedWidgetCommand command,
      ) =>
        await _route(command),
    };
  }

  Future<Result<CommittedCommandResult>> _route(
    VerifiedWidgetCommand command,
  ) async {
    for (final WidgetCommandHandler handler in handlers) {
      if (handler.supports(command.action)) {
        try {
          return await handler.handle(command).timeout(hostTimeout);
        } on TimeoutException {
          // Fail safe: surface a retryable unavailable result. The action is
          // idempotent (derived command id + receipt), so a retry replays the
          // committed receipt or commits exactly once — never a duplicate.
          return Failed<CommittedCommandResult>(
            Failure(
              kind: FailureKind.unavailableCapability,
              code: 'widget.action_timeout.${command.action.wireName}',
              safeMessageKey: 'error.widget.action_timeout',
              retryable: true,
              redactedCause: 'timeout',
            ),
          );
        }
      }
    }
    return Failed<CommittedCommandResult>(
      Failure(
        kind: FailureKind.unavailableCapability,
        code: 'widget.action_unhandled.${command.action.wireName}',
        safeMessageKey: 'error.widget.action_unavailable',
        retryable: false,
        redactedCause: command.action.name,
      ),
    );
  }
}
