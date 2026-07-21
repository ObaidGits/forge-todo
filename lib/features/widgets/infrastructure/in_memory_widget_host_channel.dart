/// A deterministic in-memory widget host channel (R-WIDGET-002).
///
/// Stands in for the native shared-container channel until the platform channel
/// (task 11.2) is built. It serializes each published snapshot through the
/// canonical codec exactly as the platform channel will, so the encoded bytes a
/// widget would read are exercised here. Reads always round-trip through
/// [WidgetSnapshotCodec.decode], surfacing version-mismatch fallback behavior.
library;

import 'package:forge/features/widgets/application/widget_bridge.dart';
import 'package:forge/features/widgets/domain/widget_snapshot.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';

final class InMemoryWidgetHostChannel implements WidgetHostChannel {
  final Map<String, String> _encodedBySurface = <String, String>{};

  /// The number of publishes observed, for reconciliation assertions.
  int publishCount = 0;

  @override
  Future<void> publish(WidgetSnapshot snapshot) async {
    publishCount += 1;
    _encodedBySurface[snapshot.surfaceWire] = WidgetSnapshotCodec.encode(
      snapshot,
    );
  }

  @override
  Future<void> clear(WidgetSurface surface) async {
    _encodedBySurface.remove(surface.wireName);
  }

  /// The raw bytes the container currently holds for [surface], or null.
  String? rawFor(WidgetSurface surface) => _encodedBySurface[surface.wireName];

  /// Decodes what the container would read for [surface]. Returns null when no
  /// snapshot exists or when the stored bytes fail version-safe decoding.
  WidgetSnapshot? read(WidgetSurface surface) {
    final String? raw = _encodedBySurface[surface.wireName];
    if (raw == null) {
      return null;
    }
    return WidgetSnapshotCodec.decode(raw);
  }
}
