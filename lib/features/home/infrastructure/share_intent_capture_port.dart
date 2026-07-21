/// The Android share-intent adapter behind the [InboundCapturePort]
/// (task 4.7, R-SEARCH-004).
///
/// `package:receive_sharing_intent` is imported ONLY here. It turns an inbound
/// `ACTION_SEND` text/URL share into an idempotent [InboundCaptureRequest] that
/// the plugin-free [InboundCaptureService] validates (URI policy, sanitization,
/// ownership, app-lock gate) and commits idempotently through the command bus.
///
/// The shared text/URL becomes the capture CONTENT (the task title), never a
/// protocol argument, so the deny-by-default `UriPolicy` is not tripped. The
/// [InboundCaptureRequest.deliveryId] is derived deterministically from the
/// shared content so a re-delivered share folds into the SAME durable command
/// id and never double-creates (R-GEN-005).
///
/// Every path is defensive: a malformed payload or a plugin error is dropped
/// rather than propagated, so a share can never crash the local-first app.
library;

import 'dart:async';

import 'package:forge/features/home/domain/inbound_capture.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

final class ShareIntentCapturePort implements InboundCapturePort {
  ShareIntentCapturePort({ReceiveSharingIntent? receiver})
    : _receiver = receiver ?? ReceiveSharingIntent.instance {
    _controller = StreamController<InboundCaptureRequest>.broadcast(
      onListen: _start,
      onCancel: _stop,
    );
  }

  final ReceiveSharingIntent _receiver;
  late final StreamController<InboundCaptureRequest> _controller;
  StreamSubscription<List<SharedMediaFile>>? _subscription;

  @override
  Stream<InboundCaptureRequest> get captures => _controller.stream;

  void _start() {
    // A share that launched the app is delivered once via getInitialMedia; live
    // shares arrive on the media stream. Both are mapped through the same path.
    unawaited(_drainInitial());
    try {
      _subscription = _receiver.getMediaStream().listen(
        _emitAll,
        onError: (Object _, StackTrace _) {},
      );
    } on Object {
      // A device/plugin without share support degrades to no deliveries.
    }
  }

  Future<void> _drainInitial() async {
    try {
      final List<SharedMediaFile> initial = await _receiver.getInitialMedia();
      _emitAll(initial);
      // Consume the callback so a relaunch does not replay the same initial
      // share; idempotency still protects against any accidental replay.
      await _receiver.reset();
    } on Object {
      // No initial share (or unsupported) — nothing to drain.
    }
  }

  void _emitAll(List<SharedMediaFile> files) {
    for (final SharedMediaFile file in files) {
      final InboundCaptureRequest? request = _toRequest(file);
      if (request != null && !_controller.isClosed) {
        _controller.add(request);
      }
    }
  }

  InboundCaptureRequest? _toRequest(SharedMediaFile file) {
    // Only text and URL shares become a quick capture; media/file shares are
    // out of scope for V1 capture and are ignored.
    if (file.type != SharedMediaType.text && file.type != SharedMediaType.url) {
      return null;
    }
    final String content = (file.message ?? file.path).trim();
    if (content.isEmpty) {
      return null;
    }
    return InboundCaptureRequest(
      source: CaptureSource.shareIntent,
      deliveryId: _deliveryId(content),
      sharedText: content,
    );
  }

  /// A stable, id-safe delivery id derived from the shared content via a 64-bit
  /// FNV-1a digest, so the same shared content maps to the same idempotent
  /// command id on re-delivery.
  static String _deliveryId(String content) {
    const int fnvOffset = 0xcbf29ce484222325;
    const int fnvPrime = 0x100000001b3;
    int hash = fnvOffset;
    for (final int byte in content.codeUnits) {
      hash = (hash ^ byte) * fnvPrime;
      hash &= 0xffffffffffffffff;
    }
    return 'share-${hash.toRadixString(16).padLeft(16, '0')}';
  }

  void _stop() {
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  /// Releases the underlying subscription. Safe to call more than once.
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}
