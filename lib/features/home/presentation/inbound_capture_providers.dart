import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/routing/uri_policy.dart';
import 'package:forge/core/security/app_lock.dart';
import 'package:forge/features/home/application/inbound_capture_service.dart';
import 'package:forge/features/home/domain/inbound_capture.dart';
import 'package:forge/features/home/presentation/home_providers.dart';
import 'package:forge/features/notes/application/note_command_service.dart';

// ---------------------------------------------------------------------------
// Composition seams for inbound (OS-originated) quick capture (R-SEARCH-004).
// Defaults keep the running app safe before native adapters are wired; the
// composition root and tests override them.
// ---------------------------------------------------------------------------

/// The centralized inbound/outbound/desktop-argument URI policy (design.md §7).
/// Defaults to the deny-by-default policy; the root may widen allowlists.
final Provider<UriPolicy> uriPolicyProvider = Provider<UriPolicy>(
  (Ref ref) => UriPolicy(),
);

/// The presentation/session lock gate (R-SEC-003). Defaults to an always-open
/// (unconfigured) gate so the app is usable before a lock is configured; the
/// security composition overrides it with the live gate.
final Provider<AppLockGate> appLockGateProvider = Provider<AppLockGate>(
  (Ref ref) => AppLockGate(elapsed: () => Duration.zero),
);

/// The OS share-intent/desktop-protocol/global-shortcut adapter. Null until a
/// native adapter is composed at the root (design.md §9).
final Provider<InboundCapturePort?> inboundCapturePortProvider =
    Provider<InboundCapturePort?>((Ref ref) => null);

/// The notes command contract used when a share targets a note
/// (R-NOTE-001, R-SEARCH-004). Null until the notes stack is wired, in which
/// case a note-intent capture is refused as unavailable.
final Provider<NoteCommandService?> captureNoteCommandServiceProvider =
    Provider<NoteCommandService?>((Ref ref) => null);

/// The validated, ownership-checked, lock-gated, idempotent capture pipeline.
final Provider<InboundCaptureService> inboundCaptureServiceProvider =
    Provider<InboundCaptureService>(
      (Ref ref) =>
          InboundCaptureService(uriPolicy: ref.watch(uriPolicyProvider)),
    );

// ---------------------------------------------------------------------------
// Inbound capture controller.
// ---------------------------------------------------------------------------

/// Subscribes to the inbound capture port and processes each OS-delivered
/// request through [InboundCaptureService], exposing the latest [CaptureOutcome]
/// so the shell can react (reload Today on commit, route to the lock screen
/// when gated, surface a refusal otherwise). Holds no domain rules.
final class InboundCaptureController extends Notifier<CaptureOutcome?> {
  @override
  CaptureOutcome? build() {
    final InboundCapturePort? port = ref.watch(inboundCapturePortProvider);
    if (port == null) {
      return null;
    }
    final StreamSubscription<InboundCaptureRequest> subscription = port.captures
        .listen(_onRequest);
    ref.onDispose(subscription.cancel);
    return null;
  }

  Future<void> _onRequest(InboundCaptureRequest request) async {
    final CaptureOutcome outcome = await process(request);
    state = outcome;
    if (outcome is CaptureCommitted) {
      ref.read(homeControllerProvider.notifier).reload();
    }
  }

  /// Processes a single request. Exposed for direct invocation (e.g. a global
  /// shortcut payload dispatched from the shell) and for testing.
  Future<CaptureOutcome> process(InboundCaptureRequest request) {
    return ref
        .read(inboundCaptureServiceProvider)
        .capture(
          request: request,
          ownership: CaptureOwnership(
            profileId: ref.read(activeProfileProvider),
            lifeAreaId: ref.read(quickCaptureAreaProvider),
            commands: ref.read(taskCommandServiceProvider),
            noteCommands: ref.read(captureNoteCommandServiceProvider),
          ),
          lock: ref.read(appLockGateProvider),
        );
  }

  /// Clears the last outcome once the shell has reacted to it.
  void acknowledge() => state = null;
}

final NotifierProvider<InboundCaptureController, CaptureOutcome?>
inboundCaptureControllerProvider =
    NotifierProvider<InboundCaptureController, CaptureOutcome?>(
      InboundCaptureController.new,
    );
