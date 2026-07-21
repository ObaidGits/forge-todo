/// Inbound quick-capture domain model and OS port (R-SEARCH-004).
///
/// Quick capture must be reachable from every main route, a desktop shortcut,
/// and supported mobile share intents. This module models the *external* entry
/// points (share intent, desktop protocol argument, global shortcut) as pure
/// values behind a plugin-free port, so the capture pipeline is testable
/// without native plugins (design.md §9).
library;

/// The originating OS surface of an inbound quick capture.
enum CaptureSource {
  /// A supported mobile share intent delivering shared text/URL.
  shareIntent,

  /// A desktop protocol/file argument (e.g. `forge://app/...`).
  desktopArgument,

  /// A registered desktop/global keyboard shortcut payload.
  globalShortcut,
}

extension CaptureSourceCode on CaptureSource {
  /// A short, id-safe discriminator used when deriving a stable command id.
  String get code => switch (this) {
    CaptureSource.shareIntent => 'share',
    CaptureSource.desktopArgument => 'arg',
    CaptureSource.globalShortcut => 'key',
  };
}

/// What kind of record an inbound capture creates (R-SEARCH-004, R-TASK-001,
/// R-NOTE-001).
///
/// Quick capture defaults to a title-only task. A surface that shares longer or
/// explicitly note-shaped content (e.g. a "new note" share target) requests a
/// canonical Markdown note instead, so the captured content lands in the single
/// canonical note system rather than a task title.
enum CaptureIntentKind {
  /// Create a title-only task (the default quick-capture behavior).
  task,

  /// Create a canonical Markdown note from the shared content.
  note,
}

/// An OS-delivered quick-capture request originating outside the app.
///
/// [deliveryId] is the OS-stable identifier for this specific delivery. The
/// same delivery re-sent by the OS (a re-delivered share, a relaunched
/// protocol argument) carries the same id, which is folded into a stable
/// command id so a re-delivery never double-creates (R-GEN-005).
///
/// [uri] is the addressing/protocol argument, validated through the
/// centralized [UriPolicy] (scheme/host/route allowlists, opaque-ID parsing,
/// size and canonicalization limits). It never carries user content.
///
/// [sharedText] is the optional content payload that becomes the captured task
/// title. It is size-bounded and sanitized and is never placed in an external
/// URL (R-SEC-005).
final class InboundCaptureRequest {
  const InboundCaptureRequest({
    required this.source,
    required this.deliveryId,
    this.uri,
    this.sharedText,
    this.intent = CaptureIntentKind.task,
  });

  final CaptureSource source;
  final String deliveryId;
  final String? uri;
  final String? sharedText;

  /// The kind of record this capture creates (R-SEARCH-004). Defaults to a
  /// title-only task; a note-shaped share sets [CaptureIntentKind.note].
  final CaptureIntentKind intent;
}

/// The port over the OS share-intent, desktop-protocol, and global-shortcut
/// channels.
///
/// The concrete adapter (native plugins/platform channels) is composed at the
/// app root; the port keeps the domain and application layers plugin-free so
/// the capture pipeline is fully testable with a fake stream (design.md §9).
/// The adapter owns cancellation of any underlying subscription and is
/// expected to hold and re-deliver a capture that arrived while the session
/// was locked, using the same [InboundCaptureRequest.deliveryId].
abstract interface class InboundCapturePort {
  /// A broadcast stream of inbound capture deliveries.
  Stream<InboundCaptureRequest> get captures;
}
