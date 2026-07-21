/// A local-only, in-memory widget snapshot store (R-WIDGET-002).
///
/// The default snapshot store until a platform-backed shared container store
/// exists. Snapshots are held per surface and never leave the device: this
/// store enqueues no outbox work and performs no sync, honoring the
/// `widget_snapshot` local-only classification in the data model.
library;

import 'package:forge/features/widgets/domain/widget_snapshot.dart';
import 'package:forge/features/widgets/domain/widget_snapshot_repository.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';

final class InMemoryWidgetSnapshotStore implements WidgetSnapshotRepository {
  final Map<String, WidgetSnapshot> _bySurface = <String, WidgetSnapshot>{};

  @override
  Future<void> save(WidgetSnapshot snapshot) async {
    _bySurface[snapshot.surfaceWire] = snapshot;
  }

  @override
  Future<WidgetSnapshot?> load(WidgetSurface surface) async =>
      _bySurface[surface.wireName];

  @override
  Future<List<WidgetSnapshot>> loadAll() async => <WidgetSnapshot>[
    for (final WidgetSurface surface in WidgetSurface.values)
      if (_bySurface[surface.wireName] != null) _bySurface[surface.wireName]!,
  ];

  @override
  Future<void> clear(WidgetSurface surface) async {
    _bySurface.remove(surface.wireName);
  }
}
