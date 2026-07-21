/// Redacted, versioned widget snapshots (R-WIDGET-002, R-WIDGET-004).
///
/// A [WidgetSnapshot] is the minimal, redacted projection the app writes for a
/// home-screen widget to render WITHOUT ever opening the primary encrypted
/// database (R-WIDGET-002). Every snapshot:
///
///   * carries a schema/format [version] so a native container built against an
///     older format degrades safely instead of misreading newer bytes;
///   * stamps [generatedAtUtcMicros] and a [stalenessThresholdSeconds] so a
///     widget can honestly show a "stale" indicator rather than wrong data
///     (R-WIDGET-003 stale state);
///   * respects app-lock/privacy state through the [redacted] flag: a redacted
///     snapshot carries NO item content and NO counts (R-WIDGET-004);
///   * is local-only. Snapshots are never enqueued to the outbox and never
///     synced (data-model: `widget_snapshot` is local-only).
///
/// The model is pure Dart with a deterministic canonical codec so the same
/// logical snapshot always serializes to the same bytes.
library;

import 'dart:convert';

/// Freshness of a snapshot relative to a read-time clock.
enum WidgetFreshness { fresh, stale }

/// A single glanceable line in a widget snapshot.
///
/// Content fields are only ever populated in a non-redacted snapshot; a
/// redacted snapshot carries an empty item list.
final class WidgetSnapshotItem {
  WidgetSnapshotItem({
    required this.id,
    required this.title,
    this.subtitle,
    this.isComplete = false,
    this.countdownRemainingSeconds,
  }) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'Must not be empty.');
    }
    if (countdownRemainingSeconds != null && countdownRemainingSeconds! < 0) {
      throw ArgumentError.value(
        countdownRemainingSeconds,
        'countdownRemainingSeconds',
        'Must be nonnegative.',
      );
    }
  }

  /// Opaque entity id used only as an intent target; never a title/URL.
  final String id;

  /// Short display title, clamped by the builder to [WidgetSnapshot.maxTextLength].
  final String title;

  /// Optional secondary line (e.g. due time), also clamped.
  final String? subtitle;

  /// Whether the item shows as done (task/habit).
  final bool isComplete;

  /// Remaining seconds for a countdown surface, or null.
  final int? countdownRemainingSeconds;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    if (subtitle != null) 'subtitle': subtitle,
    'complete': isComplete,
    if (countdownRemainingSeconds != null)
      'countdown_seconds': countdownRemainingSeconds,
  };

  static WidgetSnapshotItem fromJson(Map<String, Object?> json) =>
      WidgetSnapshotItem(
        id: json['id']! as String,
        title: json['title']! as String,
        subtitle: json['subtitle'] as String?,
        isComplete: (json['complete'] as bool?) ?? false,
        countdownRemainingSeconds: json['countdown_seconds'] as int?,
      );

  @override
  bool operator ==(Object other) =>
      other is WidgetSnapshotItem &&
      other.id == id &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.isComplete == isComplete &&
      other.countdownRemainingSeconds == countdownRemainingSeconds;

  @override
  int get hashCode =>
      Object.hash(id, title, subtitle, isComplete, countdownRemainingSeconds);
}

/// A redacted, versioned, local-only snapshot for one widget surface.
final class WidgetSnapshot {
  WidgetSnapshot({
    required this.version,
    required this.surfaceWire,
    required this.profileId,
    required this.generatedAtUtcMicros,
    required this.stalenessThresholdSeconds,
    required this.redacted,
    required List<WidgetSnapshotItem> items,
  }) : items = List<WidgetSnapshotItem>.unmodifiable(items) {
    if (stalenessThresholdSeconds <= 0) {
      throw ArgumentError.value(
        stalenessThresholdSeconds,
        'stalenessThresholdSeconds',
        'Must be positive.',
      );
    }
    if (redacted && this.items.isNotEmpty) {
      throw ArgumentError.value(
        items,
        'items',
        'A redacted snapshot must carry no item content.',
      );
    }
    if (this.items.length > maxItems) {
      throw ArgumentError.value(
        items,
        'items',
        'Exceeds the widget snapshot item cap.',
      );
    }
  }

  /// The current snapshot format/schema version. Bump when the shape changes.
  static const int currentVersion = 1;

  /// Maximum number of items a snapshot may carry. The builder truncates.
  static const int maxItems = 8;

  /// Maximum display length of any single text field. The builder clamps.
  static const int maxTextLength = 80;

  final int version;
  final String surfaceWire;
  final String profileId;
  final int generatedAtUtcMicros;
  final int stalenessThresholdSeconds;

  /// True when app-lock/privacy hid content; items are then always empty.
  final bool redacted;

  final List<WidgetSnapshotItem> items;

  /// Freshness relative to [nowUtcMicros]. A snapshot older than its staleness
  /// threshold is [WidgetFreshness.stale]; a future-stamped snapshot (clock
  /// skew) is treated as fresh.
  WidgetFreshness freshnessAt(int nowUtcMicros) {
    final int ageMicros = nowUtcMicros - generatedAtUtcMicros;
    if (ageMicros <= 0) {
      return WidgetFreshness.fresh;
    }
    final int thresholdMicros = stalenessThresholdSeconds * 1000000;
    return ageMicros <= thresholdMicros
        ? WidgetFreshness.fresh
        : WidgetFreshness.stale;
  }

  bool isStaleAt(int nowUtcMicros) =>
      freshnessAt(nowUtcMicros) == WidgetFreshness.stale;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'surface': surfaceWire,
    'profile_id': profileId,
    'generated_at_utc_micros': generatedAtUtcMicros,
    'staleness_threshold_seconds': stalenessThresholdSeconds,
    'redacted': redacted,
    'items': items
        .map((WidgetSnapshotItem item) => item.toJson())
        .toList(growable: false),
  };

  @override
  bool operator ==(Object other) =>
      other is WidgetSnapshot &&
      other.version == version &&
      other.surfaceWire == surfaceWire &&
      other.profileId == profileId &&
      other.generatedAtUtcMicros == generatedAtUtcMicros &&
      other.stalenessThresholdSeconds == stalenessThresholdSeconds &&
      other.redacted == redacted &&
      _listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(
    version,
    surfaceWire,
    profileId,
    generatedAtUtcMicros,
    stalenessThresholdSeconds,
    redacted,
    Object.hashAll(items),
  );

  static bool _listEquals(
    List<WidgetSnapshotItem> a,
    List<WidgetSnapshotItem> b,
  ) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}

/// Deterministic canonical JSON codec for the shared widget container.
///
/// [encode] sorts object keys so the same logical snapshot always produces the
/// same bytes. [decode] is version-aware: a snapshot whose `version` exceeds
/// [WidgetSnapshot.currentVersion] (a newer app wrote a container an older app
/// reads) fails safe by returning null, and malformed bytes return null too —
/// the container then keeps its last good render or shows a neutral state
/// rather than crashing (testing.md §10 version-mismatch fallback).
abstract final class WidgetSnapshotCodec {
  static String encode(WidgetSnapshot snapshot) =>
      jsonEncode(_canonicalize(snapshot.toJson()));

  static WidgetSnapshot? decode(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    final Object? version = decoded['version'];
    if (version is! int || version > WidgetSnapshot.currentVersion) {
      return null;
    }
    final Object? surface = decoded['surface'];
    final Object? profileId = decoded['profile_id'];
    final Object? generatedAt = decoded['generated_at_utc_micros'];
    final Object? threshold = decoded['staleness_threshold_seconds'];
    final Object? redacted = decoded['redacted'];
    final Object? items = decoded['items'];
    if (surface is! String ||
        profileId is! String ||
        generatedAt is! int ||
        threshold is! int ||
        redacted is! bool ||
        items is! List) {
      return null;
    }
    try {
      return WidgetSnapshot(
        version: version,
        surfaceWire: surface,
        profileId: profileId,
        generatedAtUtcMicros: generatedAt,
        stalenessThresholdSeconds: threshold,
        redacted: redacted,
        items: items
            .map(
              (Object? item) =>
                  WidgetSnapshotItem.fromJson(item! as Map<String, Object?>),
            )
            .toList(growable: false),
      );
    } on Object {
      return null;
    }
  }

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final List<String> keys =
          value.keys.map((Object? k) => k as String).toList()..sort();
      return <String, Object?>{
        for (final String key in keys) key: _canonicalize(value[key]),
      };
    }
    if (value is List) {
      return value.map(_canonicalize).toList(growable: false);
    }
    return value;
  }
}
