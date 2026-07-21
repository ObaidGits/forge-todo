/// Widget bridge contracts (design §9 `WidgetBridge`, R-WIDGET-002/003/004).
///
/// These are the stable ports between the app and the native widget container.
/// The concrete platform channel is built in a later task; this layer defines
/// the contracts and is exercised with deterministic fakes.
library;

import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/widgets/domain/widget_intent.dart';
import 'package:forge/features/widgets/domain/widget_snapshot.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';

/// The app-facing widget bridge (design §9).
///
/// [publish] pushes a redacted, versioned snapshot to the shared container so a
/// widget can render without opening the encrypted database (R-WIDGET-002).
/// [execute] receives an untrusted widget-originated [WidgetIntent], verifies it
/// (spoof resistance), routes it through an idempotent durable command, and
/// returns the committed receipt (R-WIDGET-003, R-GEN-005) — never a dispatch
/// acknowledgement.
abstract interface class WidgetBridge {
  Future<void> publish(WidgetSnapshot snapshot);

  Future<Result<CommittedCommandResult>> execute(WidgetIntent intent);
}

/// Outbound channel to the native widget container.
///
/// The default in-memory implementation is local-only; the platform channel
/// (task 11.2) replaces it. Snapshots are always serialized through the
/// canonical codec by the caller.
abstract interface class WidgetHostChannel {
  Future<void> publish(WidgetSnapshot snapshot);

  Future<void> clear(WidgetSurface surface);
}

/// Signs and verifies the authentication tag on widget intents (spoof
/// resistance, R-WIDGET-003). The concrete platform provides the real keyed
/// signer; the contract is a swappable port.
abstract interface class WidgetIntentSigner {
  /// Produces an authentication tag over [canonicalPayload].
  String sign(String canonicalPayload);

  /// Verifies [token] against [canonicalPayload]. Implementations MUST compare
  /// in constant time and MUST NOT leak whether the payload or the tag differed.
  bool verify(String canonicalPayload, String token);
}

/// Routes a verified widget command to the owning feature's durable command
/// service via the command bus, returning the committed receipt.
///
/// This keeps the widgets feature decoupled from other features' internals: the
/// composition root wires an implementation that dispatches to the task/habit
/// application command services.
abstract interface class WidgetCommandHandler {
  /// Whether this handler can service [action].
  bool supports(WidgetIntentAction action);

  /// Executes the verified command idempotently and returns its committed
  /// receipt. Replaying the same command returns the same result.
  Future<Result<CommittedCommandResult>> handle(VerifiedWidgetCommand command);
}
