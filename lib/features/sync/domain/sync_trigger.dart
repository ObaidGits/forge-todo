/// The sources that may prompt a sync attempt and their scheduling semantics
/// (R-SYNC-005, design.md §14 "Sync batches … applies exponential backoff with
/// full jitter, and pauses under low battery/data-saver where exposed").
///
/// Sync scheduling is an acceleration/observability concern layered over the
/// authoritative local store; it never blocks local content. A trigger is only
/// a *request* to schedule work — the [SyncScheduler] decides whether and when
/// the request actually runs given connectivity, the data-saver policy, an
/// active debounce window, and any failure backoff.
library;

/// Where a sync request originated. The source determines how the scheduler
/// treats the request: user-initiated work is honored immediately and is never
/// silently deferred, background/opportunistic work may be coalesced or held
/// back under a restricted environment.
enum SyncTriggerSource {
  /// The user explicitly asked to sync (e.g. pull-to-refresh, a retry button).
  /// Manual triggers bypass the debounce window and data-saver deferral.
  manual,

  /// The app finished cold start. A launch reconciles by pushing pending work
  /// and pulling the authoritative feed.
  appLaunch,

  /// The app returned to the foreground. Treated like a launch reconcile.
  appResume,

  /// The app is moving to the background. A best-effort flush of already-queued
  /// work; deferrable under data-saver.
  appBackground,

  /// A local edit was committed. Bursts of edits are coalesced into a single
  /// debounced push rather than one push per keystroke.
  localEdit,

  /// Connectivity was (re)gained. An opportunistic reconcile that also clears
  /// any failure backoff gate so recovery is prompt.
  connectivityRegained,

  /// The device/app became idle with capacity to spare. Opportunistic.
  idle,

  /// A realtime notification hinted that the server has new changes. This is a
  /// NON-AUTHORITATIVE hint (data-model.md §6 "Realtime is only a pull hint"):
  /// it may prompt an ordered pull but its payload is never trusted as data.
  realtimeHint,
}

/// Scheduling classification of a trigger source. Pure, table-driven policy so
/// the scheduler and its tests share one source of truth.
extension SyncTriggerSemantics on SyncTriggerSource {
  /// User-initiated triggers are honored immediately: no debounce, and they are
  /// never deferred by the data-saver policy.
  bool get isUserInitiated => this == SyncTriggerSource.manual;

  /// Foreground reconcile triggers (launch/resume) push pending work and pull
  /// the authoritative feed as soon as the environment allows.
  bool get isForegroundReconcile =>
      this == SyncTriggerSource.appLaunch ||
      this == SyncTriggerSource.appResume;

  /// Local edits are the only triggers that open/extend the debounce window so
  /// a burst of edits collapses into one scheduled push.
  bool get isDebounced => this == SyncTriggerSource.localEdit;

  /// Opportunistic/background triggers run only when spare capacity exists and
  /// may be deferred under data-saver.
  bool get isOpportunistic =>
      this == SyncTriggerSource.idle ||
      this == SyncTriggerSource.connectivityRegained ||
      this == SyncTriggerSource.appBackground;

  /// Clears any failure backoff gate so recovery is immediate rather than
  /// waiting out a stale backoff. A user-initiated manual retry resets backoff
  /// (R-SYNC-005 "manual retry"), and regaining connectivity resets it because
  /// the prior failures were most likely the outage itself.
  bool get clearsBackoff =>
      this == SyncTriggerSource.connectivityRegained ||
      this == SyncTriggerSource.manual;

  /// A realtime hint may prompt an ordered pull but is never authoritative and
  /// carries no trusted data (data-model.md §6).
  bool get isRealtimeHint => this == SyncTriggerSource.realtimeHint;

  /// Background/opportunistic work may be held back when the data-saver policy
  /// restricts background sync; user-initiated and realtime-prompted pulls are
  /// not deferred by this alone.
  bool get isDeferrableUnderDataSaver => isOpportunistic;
}

/// What a sync attempt should do when it runs. Push and pull are independent:
/// pending local work drives a push; a realtime hint or reconcile drives a
/// pull; most triggers do both.
enum SyncWorkKind {
  /// Nothing to do right now.
  none,

  /// Push locally pending semantic groups only.
  push,

  /// Pull the authoritative ordered feed only (e.g. a realtime hint with no
  /// pending local work).
  pull,

  /// Push pending work then pull the authoritative feed.
  pushAndPull,
}

/// Combines two work kinds into the least-work superset (used when multiple
/// intents coalesce before a single attempt runs).
SyncWorkKind mergeWorkKind(SyncWorkKind a, SyncWorkKind b) {
  final bool push =
      a == SyncWorkKind.push ||
      a == SyncWorkKind.pushAndPull ||
      b == SyncWorkKind.push ||
      b == SyncWorkKind.pushAndPull;
  final bool pull =
      a == SyncWorkKind.pull ||
      a == SyncWorkKind.pushAndPull ||
      b == SyncWorkKind.pull ||
      b == SyncWorkKind.pushAndPull;
  if (push && pull) {
    return SyncWorkKind.pushAndPull;
  }
  if (push) {
    return SyncWorkKind.push;
  }
  if (pull) {
    return SyncWorkKind.pull;
  }
  return SyncWorkKind.none;
}
