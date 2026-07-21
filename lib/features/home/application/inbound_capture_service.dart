import 'dart:convert';

import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/routing/uri_policy.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/core/security/app_lock.dart';
import 'package:forge/features/home/domain/inbound_capture.dart';
import 'package:forge/features/notes/application/note_command_service.dart';
import 'package:forge/features/notes/application/note_commands.dart';
import 'package:forge/features/tasks/application/task_command_service.dart';
import 'package:forge/features/tasks/application/task_commands.dart';

/// Why an inbound capture was refused. The reason never echoes the rejected
/// input (R-SEC-005, mirroring [UriPolicy]).
enum CaptureRejectionReason {
  /// The addressing/protocol URI failed the centralized [UriPolicy].
  unsupportedInvocation,

  /// The shared content was empty, too long, or otherwise unusable.
  invalidContent,

  /// No profile/Life Area/command surface is available to own the capture.
  ownershipUnavailable,

  /// The command bus rejected the durable write (validation/storage/conflict).
  commitFailed,
}

/// The result of processing one [InboundCaptureRequest].
sealed class CaptureOutcome {
  const CaptureOutcome();
}

/// The capture committed durably (or replayed an existing receipt). The stable
/// committed result is carried, never a dispatch acknowledgement (R-GEN-005).
///
/// [entityType]/[entityId] identify the created record so the captured content
/// is *reachable*: the caller resolves them to a canonical route
/// (`CanonicalRoute.forEntity`) and navigates (R-SEARCH-004, R-SEARCH-002).
final class CaptureCommitted extends CaptureOutcome {
  const CaptureCommitted(
    this.result, {
    required this.entityType,
    required this.entityId,
  });

  final CommittedCommandResult result;

  /// The created record's entity type (`task` or `note`).
  final String entityType;

  /// The created record's opaque id, or null when the payload carried none
  /// (e.g. a replayed receipt without an id payload).
  final String? entityId;

  /// True when the command bus returned an existing receipt for a re-delivered
  /// intent instead of creating a second record (idempotent replay).
  bool get replayed => result.replayed;
}

/// The session is locked, so the capture is withheld rather than committed into
/// a locked surface (R-SEC-003/R-SEC-005). The content is not revealed; the
/// adapter re-delivers the same [InboundCaptureRequest.deliveryId] after unlock.
final class CaptureGated extends CaptureOutcome {
  const CaptureGated();
}

/// The capture was refused. [rejection] is populated for URI-policy failures.
final class CaptureRejected extends CaptureOutcome {
  const CaptureRejected(this.reason, {this.rejection, this.failure});

  final CaptureRejectionReason reason;
  final UriRejection? rejection;
  final Failure? failure;
}

/// Ownership context for an inbound capture: the active profile, the Life Area
/// a capture inherits (R-TASK-001), and the command contracts a capture may
/// target. [commands] owns task capture; [noteCommands] owns note capture
/// (R-NOTE-001). A null field for the requested target means capture is
/// unavailable and the request is refused.
final class CaptureOwnership {
  const CaptureOwnership({
    this.profileId,
    this.lifeAreaId,
    this.commands,
    this.noteCommands,
  });

  final ProfileId? profileId;
  final LifeAreaId? lifeAreaId;
  final TaskCommandService? commands;
  final NoteCommandService? noteCommands;

  /// Common ownership: an active profile and inherited Life Area exist.
  bool get _hasOwner => profileId != null && lifeAreaId != null;

  /// True when a title-only task capture can be committed.
  bool get isAvailable => _hasOwner && commands != null;

  /// True when the [intent] target can be committed with this ownership.
  bool availableFor(CaptureIntentKind intent) => switch (intent) {
    CaptureIntentKind.task => isAvailable,
    CaptureIntentKind.note => _hasOwner && noteCommands != null,
  };
}

/// Derives a stable [CommandId] for a delivery so the command bus deduplicates
/// a re-delivered share/intent (R-GEN-005).
typedef CaptureCommandId =
    CommandId Function(CaptureSource source, String deliveryId);

/// Validates and commits inbound quick captures from OS entry points.
///
/// Every inbound path is: (1) validated through the centralized [UriPolicy];
/// (2) content-bounded and sanitized; (3) profile-owned; (4) app-lock/privacy
/// gated (R-SEC-003/R-SEC-005); and (5) committed idempotently through the
/// tasks command bus with a stable command id (R-GEN-005). The service holds no
/// mutable state and performs no plugin/DB work of its own — it composes the
/// existing policy, lock gate, and command contract.
final class InboundCaptureService {
  InboundCaptureService({
    required this.uriPolicy,
    this.maximumTitleLength = 512,
    CaptureCommandId? commandIdFor,
  }) : _commandIdFor = commandIdFor ?? defaultCaptureCommandId;

  final UriPolicy uriPolicy;
  final CaptureCommandId _commandIdFor;

  /// The maximum accepted length of a sanitized capture title, in code units.
  /// A longer payload is refused rather than silently truncated so no content
  /// is dropped without the user knowing.
  final int maximumTitleLength;

  Future<CaptureOutcome> capture({
    required InboundCaptureRequest request,
    required CaptureOwnership ownership,
    required AppLockGate lock,
  }) async {
    // 1. URI / protocol-argument validation through the centralized policy.
    final String? uri = request.uri;
    if (uri != null) {
      final UriPolicyDecision decision =
          request.source == CaptureSource.desktopArgument
          ? uriPolicy.evaluateDesktopArguments(<String>[uri])
          : uriPolicy.evaluateInbound(uri);
      if (!decision.allowed) {
        return CaptureRejected(
          CaptureRejectionReason.unsupportedInvocation,
          rejection: decision.rejection,
        );
      }
    }

    // 2. Content validation and sanitization (size limits, no control chars).
    final String? title = _sanitizeTitle(request.sharedText);
    if (title == null) {
      return const CaptureRejected(CaptureRejectionReason.invalidContent);
    }

    // 3. Ownership: capture must belong to the active profile/area and have a
    //    command contract for the requested target.
    if (!ownership.availableFor(request.intent)) {
      return const CaptureRejected(CaptureRejectionReason.ownershipUnavailable);
    }

    // 4. Lock/privacy gate: never capture into a locked/withheld surface
    //    without the appropriate gate (R-SEC-003/R-SEC-005). The content is
    //    not revealed; the adapter re-delivers after unlock.
    if (!lock.isContentVisible) {
      return const CaptureGated();
    }

    // 5. Idempotent commit through the command bus with a stable id.
    final CommandId commandId = _commandIdFor(
      request.source,
      request.deliveryId,
    );
    return switch (request.intent) {
      CaptureIntentKind.task => _commit(
        entityType: _taskEntityType,
        commit: () => ownership.commands!.create(
          commandId: commandId,
          profileId: ownership.profileId!,
          input: CreateTaskInput(
            lifeAreaId: ownership.lifeAreaId!,
            title: title,
          ),
        ),
      ),
      CaptureIntentKind.note => _commit(
        entityType: _noteEntityType,
        commit: () => ownership.noteCommands!.create(
          commandId: commandId,
          profileId: ownership.profileId!,
          input: CreateNoteInput(
            lifeAreaId: ownership.lifeAreaId!,
            title: title,
          ),
        ),
      ),
    };
  }

  static const String _taskEntityType = 'task';
  static const String _noteEntityType = 'note';

  Future<CaptureOutcome> _commit({
    required String entityType,
    required Future<Result<CommittedCommandResult>> Function() commit,
  }) async {
    final Result<CommittedCommandResult> result = await commit();
    return result.fold(
      success: (CommittedCommandResult committed) => CaptureCommitted(
        committed,
        entityType: entityType,
        entityId: _idFromPayload(committed.resultPayload),
      ),
      failure: (Failure failure) => CaptureRejected(
        CaptureRejectionReason.commitFailed,
        failure: failure,
      ),
    );
  }

  static String? _idFromPayload(String? payload) {
    if (payload == null || payload.isEmpty) {
      return null;
    }
    final Object? decoded = jsonDecode(payload);
    if (decoded is Map<String, Object?> && decoded['id'] is String) {
      return decoded['id'] as String;
    }
    return null;
  }

  /// Trims, strips control characters, and enforces the size bound. Returns
  /// null when the payload is missing, empty after sanitization, or too long.
  String? _sanitizeTitle(String? raw) {
    if (raw == null) {
      return null;
    }
    final StringBuffer buffer = StringBuffer();
    for (final int rune in raw.runes) {
      // Drop C0/C1 control characters (newlines, tabs, NUL, DEL, ...) that
      // could break a single-line title or smuggle terminal control sequences.
      final bool isControl = rune < 0x20 || (rune >= 0x7F && rune <= 0x9F);
      buffer.writeCharCode(isControl ? 0x20 : rune);
    }
    final String collapsed = buffer
        .toString()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (collapsed.isEmpty || collapsed.length > maximumTitleLength) {
      return null;
    }
    return collapsed;
  }
}

/// The default stable command-id derivation: a 64-bit FNV-1a digest of the
/// delivery id, namespaced by source. The same delivery always maps to the
/// same id, and the value satisfies the [CommandId] identifier grammar.
CommandId defaultCaptureCommandId(CaptureSource source, String deliveryId) {
  const int fnvOffset = 0xcbf29ce484222325;
  const int fnvPrime = 0x100000001b3;
  int hash = fnvOffset;
  for (final int byte in deliveryId.codeUnits) {
    hash = (hash ^ byte) * fnvPrime;
    hash &= 0xffffffffffffffff;
  }
  final String digest = hash.toRadixString(16).padLeft(16, '0');
  return CommandId('cap-${source.code}-$digest');
}
