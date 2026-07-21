/// Protocol-v2 client constants and primitive value types (design.md §6,
/// data-model.md §6).
///
/// Forge's optional sync is an adapter over stable application contracts; these
/// primitives are pure domain values with no Drift/Flutter/Supabase imports so
/// they can be reasoned about and property-tested independently of any backend
/// (R-SYNC-007). The wire protocol version is fixed at 2.
library;

/// The wire protocol version negotiated between client and server. Every push
/// envelope carries this value and pull cursors are only valid within the same
/// major protocol (data-model.md §6 "protocol_version": 2).
const int kSyncProtocolVersion = 2;

/// A server generation identifier that invalidates pushes from devices older
/// than retained tombstones (glossary "Snapshot epoch"; R-SYNC-003).
///
/// Epochs are monotonically increasing nonnegative integers assigned by the
/// server. A device holding a stale epoch must pull/bootstrap before it may
/// push again; a stale-epoch push is rejected before mutation.
final class SnapshotEpoch implements Comparable<SnapshotEpoch> {
  SnapshotEpoch(this.value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'Epoch must be nonnegative.');
    }
  }

  /// The genesis epoch used before the first server acceptance.
  static final SnapshotEpoch genesis = SnapshotEpoch(0);

  final int value;

  bool isStaleAgainst(SnapshotEpoch server) => value < server.value;

  @override
  int compareTo(SnapshotEpoch other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      other is SnapshotEpoch && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'SnapshotEpoch($value)';
}

/// A per-owner, monotonically increasing server sequence number. Pull pages are
/// ordered by `server_seq`; the client tracks the highest applied value in its
/// cursor (data-model.md §6 "each owner has a monotonically increasing
/// server_seq").
final class ServerSeq implements Comparable<ServerSeq> {
  ServerSeq(this.value) {
    if (value < 0) {
      throw ArgumentError.value(
        value,
        'value',
        'Server sequence must be nonnegative.',
      );
    }
  }

  /// The sequence held before any change has been applied.
  static final ServerSeq zero = ServerSeq(0);

  final int value;

  @override
  int compareTo(ServerSeq other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) => other is ServerSeq && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ServerSeq($value)';
}
