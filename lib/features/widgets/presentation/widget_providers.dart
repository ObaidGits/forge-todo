/// Composition seams for the home-screen widget bridge (R-WIDGET-002/003/004).
///
/// The widget bridge is a mobile-only capability. These seams default to null
/// so desktop and the pre-wire app are unaffected; the composition root
/// overrides them with the constructed concretes (the `home_widget` host
/// channel, the keyed-hash signer, the task/habit command handlers, and the
/// publisher) on platforms that host widgets.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/features/widgets/application/widget_bridge.dart';
import 'package:forge/features/widgets/application/widget_publisher.dart';

/// The app-facing widget bridge. Null until wired on mobile.
final Provider<WidgetBridge?> widgetBridgeProvider = Provider<WidgetBridge?>(
  (Ref ref) => null,
);

/// The app-side snapshot publisher that refreshes the widget surfaces from the
/// local canonical state. Null until wired on mobile.
final Provider<WidgetPublisher?> widgetPublisherProvider =
    Provider<WidgetPublisher?>((Ref ref) => null);
