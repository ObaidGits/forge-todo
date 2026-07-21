/// Builds redacted, versioned widget snapshots (R-WIDGET-002, R-WIDGET-004).
///
/// The builder is the single place that enforces the snapshot invariants:
///
///   * **Privacy / redaction (R-WIDGET-004):** when content is not visible
///     (app lock engaged or the "hide widget previews" privacy control is on),
///     the snapshot is redacted — it carries no item content and no counts.
///   * **Freshness (R-WIDGET-003):** every snapshot is stamped with the current
///     UTC time and a staleness threshold so the widget can show a "stale"
///     indicator honestly.
///   * **Versioning (R-WIDGET-002):** every snapshot carries the current schema
///     version.
///   * **Bounded, deterministic content:** items are truncated to a fixed cap
///     and text is clamped, in the caller-provided order, so the container
///     renders predictably and cannot be flooded.
library;

import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/widgets/domain/widget_snapshot.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';

final class WidgetSnapshotBuilder {
  const WidgetSnapshotBuilder({
    required this.clock,
    this.defaultStaleness = const Duration(minutes: 30),
  });

  final Clock clock;

  /// Default staleness threshold applied when a surface does not specify one.
  final Duration defaultStaleness;

  /// Builds a snapshot for [surface].
  ///
  /// When [contentVisible] is false the result is redacted regardless of the
  /// supplied [items]. Otherwise items are clamped and truncated deterministically.
  WidgetSnapshot build({
    required WidgetSurface surface,
    required ProfileId profileId,
    required List<WidgetSnapshotItem> items,
    required bool contentVisible,
    Duration? staleness,
  }) {
    final int nowMicros = clock.utcNow().toUtc().microsecondsSinceEpoch;
    final int thresholdSeconds = (staleness ?? defaultStaleness).inSeconds;

    if (!contentVisible) {
      // Redacted surface: no content, no counts (R-WIDGET-004).
      return WidgetSnapshot(
        version: WidgetSnapshot.currentVersion,
        surfaceWire: surface.wireName,
        profileId: profileId.value,
        generatedAtUtcMicros: nowMicros,
        stalenessThresholdSeconds: thresholdSeconds,
        redacted: true,
        items: const <WidgetSnapshotItem>[],
      );
    }

    final List<WidgetSnapshotItem> bounded = items
        .take(WidgetSnapshot.maxItems)
        .map(_clampItem)
        .toList(growable: false);

    return WidgetSnapshot(
      version: WidgetSnapshot.currentVersion,
      surfaceWire: surface.wireName,
      profileId: profileId.value,
      generatedAtUtcMicros: nowMicros,
      stalenessThresholdSeconds: thresholdSeconds,
      redacted: false,
      items: bounded,
    );
  }

  static WidgetSnapshotItem _clampItem(WidgetSnapshotItem item) {
    return WidgetSnapshotItem(
      id: item.id,
      title: _clampText(item.title),
      subtitle: item.subtitle == null ? null : _clampText(item.subtitle!),
      isComplete: item.isComplete,
      countdownRemainingSeconds: item.countdownRemainingSeconds,
    );
  }

  static String _clampText(String value) {
    if (value.length <= WidgetSnapshot.maxTextLength) {
      return value;
    }
    // Reserve one code unit for the ellipsis so the total stays within the cap.
    return '${value.substring(0, WidgetSnapshot.maxTextLength - 1)}\u2026';
  }
}
