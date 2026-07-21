/// Declares which domain tables participate in the V1 human-readable
/// export/import (`R-BACKUP-005`) and how each is keyed and tombstoned.
///
/// The set is intentionally the user-portable classifiable aggregates and
/// taxonomy — not operational, security, sync, search, or generation state,
/// which never leaves the device in a human-readable projection and would be
/// meaningless (or unsafe) outside the owning generation. Keeping the config
/// declarative and cipher/database-neutral lets it be unit-tested in isolation
/// and reused across every format.
library;

/// One exportable table: its name, primary-key column, and the tombstone
/// column used to detect soft deletion (`R-GEN-003`). A null [tombstoneColumn]
/// means the table has no soft-deletion marker.
final class PortableTable {
  const PortableTable({
    required this.name,
    this.primaryKeyColumn = 'id',
    this.tombstoneColumn = 'deleted_at_utc',
  });

  final String name;
  final String primaryKeyColumn;
  final String? tombstoneColumn;
}

/// The default portable table set, ordered parent-before-child so a
/// human-readable export reads top-to-bottom in a sensible order and imports
/// can insert parents first.
///
/// Tables absent from a given store (feature not yet built, or shipped later)
/// are simply skipped by the exporter, so this list can safely name the full
/// V1 domain surface.
const List<PortableTable> defaultPortableTables = <PortableTable>[
  PortableTable(name: 'life_areas'),
  PortableTable(name: 'tags'),
  PortableTable(name: 'tasks'),
  PortableTable(name: 'goals'),
  PortableTable(name: 'roadmaps'),
  PortableTable(name: 'roadmap_sections'),
  PortableTable(name: 'roadmap_topics'),
  PortableTable(name: 'checklist_items', tombstoneColumn: null),
  PortableTable(name: 'courses'),
  PortableTable(name: 'learning_items'),
  PortableTable(name: 'habits'),
  PortableTable(name: 'notes'),
  PortableTable(name: 'workout_templates'),
  PortableTable(name: 'workout_sessions'),
  PortableTable(name: 'body_measurements', tombstoneColumn: null),
];
