/// The platform [WidgetHostChannel] backed by a method channel (task 11.2).
///
/// This is the production channel that replaces [InMemoryWidgetHostChannel] on
/// mobile. It serializes each snapshot through the SAME canonical codec the
/// in-memory channel uses, then hands the bytes to the native host over the
/// [WidgetPlatformContract.hostChannel] method channel. The native host writes
/// them into the shared container (Android `SharedPreferences`, iOS app-group
/// `UserDefaults`) that the home-screen widgets read WITHOUT ever touching the
/// encrypted database (R-WIDGET-002).
///
/// It is deliberately thin and stateless: all redaction/freshness/versioning
/// invariants are enforced upstream by the snapshot builder, and the canonical
/// bytes are identical to what the fast tests exercise.
library;

import 'package:flutter/services.dart';
import 'package:forge/features/widgets/application/widget_bridge.dart';
import 'package:forge/features/widgets/domain/widget_platform_contract.dart';
import 'package:forge/features/widgets/domain/widget_snapshot.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';

final class PlatformWidgetHostChannel implements WidgetHostChannel {
  PlatformWidgetHostChannel({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel(WidgetPlatformContract.hostChannel);

  final MethodChannel _channel;

  @override
  Future<void> publish(WidgetSnapshot snapshot) async {
    await _channel.invokeMethod<void>(
      WidgetPlatformContract.methodPublish,
      <String, Object?>{
        WidgetPlatformContract.paramSurface: snapshot.surfaceWire,
        'payload': WidgetSnapshotCodec.encode(snapshot),
      },
    );
  }

  @override
  Future<void> clear(WidgetSurface surface) async {
    await _channel.invokeMethod<void>(
      WidgetPlatformContract.methodClear,
      <String, Object?>{WidgetPlatformContract.paramSurface: surface.wireName},
    );
  }

  /// Publishes the shared bridge [secret] so the native container can sign
  /// outbound intents. Called on unlock; the secret is local-only.
  Future<void> publishSecret(String secret) async {
    await _channel.invokeMethod<void>(
      WidgetPlatformContract.methodPublishSecret,
      <String, Object?>{'secret': secret},
    );
  }
}
