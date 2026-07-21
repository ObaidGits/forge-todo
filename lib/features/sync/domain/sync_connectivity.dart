/// The connectivity and data-saver environment the sync scheduler observes
/// (design.md §14 "pauses under low battery/data-saver where exposed";
/// NFR-PERF-005 "preserve battery/network preferences").
///
/// These are pure value types injected into the scheduler through a
/// connectivity port; production adapters map OS connectivity/data-saver
/// signals onto them, and tests supply fakes. No Flutter or platform imports
/// live here so the policy is reasoned about and property-tested in isolation.
library;

/// The coarse connectivity class the scheduler cares about. Finer transport
/// details (Wi-Fi vs. cellular generation) collapse into "can I sync at all"
/// and "is this link likely metered".
enum Connectivity {
  /// No usable network. Nothing can be pushed or pulled; work waits for a
  /// connectivity-regained trigger.
  offline,

  /// A usable but likely metered/cellular link. Background/opportunistic work
  /// is restricted when data-saver is enabled.
  metered,

  /// A usable unmetered link (e.g. Wi-Fi). Background work is unrestricted.
  unmetered,
}

/// A snapshot of the runtime sync environment. Immutable; the scheduler reads
/// the latest snapshot when it decides whether work may run now.
final class SyncEnvironment {
  const SyncEnvironment({
    required this.connectivity,
    this.dataSaverEnabled = false,
  });

  /// The default environment before any signal is observed: assume offline so
  /// the scheduler never attempts a doomed sync before connectivity is known.
  static const SyncEnvironment unknown = SyncEnvironment(
    connectivity: Connectivity.offline,
  );

  final Connectivity connectivity;

  /// Whether the OS/app data-saver preference is on. When on, background and
  /// opportunistic sync is deferred; user-initiated sync still proceeds.
  final bool dataSaverEnabled;

  /// True when the network can carry any sync traffic at all.
  bool get isOnline => connectivity != Connectivity.offline;

  /// Whether background/opportunistic sync is permitted right now. It is
  /// permitted when online and either data-saver is off or the link is
  /// unmetered (data-saver only restricts likely-metered links).
  bool get allowsBackgroundSync =>
      isOnline && (!dataSaverEnabled || connectivity == Connectivity.unmetered);

  SyncEnvironment copyWith({
    Connectivity? connectivity,
    bool? dataSaverEnabled,
  }) => SyncEnvironment(
    connectivity: connectivity ?? this.connectivity,
    dataSaverEnabled: dataSaverEnabled ?? this.dataSaverEnabled,
  );

  @override
  bool operator ==(Object other) =>
      other is SyncEnvironment &&
      other.connectivity == connectivity &&
      other.dataSaverEnabled == dataSaverEnabled;

  @override
  int get hashCode => Object.hash(connectivity, dataSaverEnabled);

  @override
  String toString() =>
      'SyncEnvironment(connectivity=${connectivity.name}, '
      'dataSaver=$dataSaverEnabled)';
}
