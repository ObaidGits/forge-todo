/// Local-only persistence port for widget snapshots (R-WIDGET-002).
///
/// Widget snapshots are local-only (data-model: `widget_snapshot`). This port
/// stores the last published snapshot per surface so the app can re-publish or
/// reconcile without touching the encrypted database, and so the native
/// container can read a redacted projection. Implementations MUST NOT enqueue
/// outbox work or otherwise route snapshots into sync.
library;

import 'package:forge/features/widgets/domain/widget_snapshot.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';

abstract interface class WidgetSnapshotRepository {
  /// Persists (or replaces) the snapshot for its surface.
  Future<void> save(WidgetSnapshot snapshot);

  /// Loads the last saved snapshot for [surface], or null if none exists.
  Future<WidgetSnapshot?> load(WidgetSurface surface);

  /// Loads every saved snapshot in deterministic surface order.
  Future<List<WidgetSnapshot>> loadAll();

  /// Removes the snapshot for [surface] if present.
  Future<void> clear(WidgetSurface surface);
}
