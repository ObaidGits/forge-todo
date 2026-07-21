/// The OS notification permission state (R-NOTIFY-002).
enum PermissionStatus {
  /// The user has not yet been asked. A contextual request is allowed.
  notDetermined,

  /// The user granted notification permission.
  granted,

  /// The user denied it, but may be asked again by the OS.
  denied,

  /// The user denied it and the OS will not present another prompt; the app
  /// must direct the user to system settings.
  permanentlyDenied;

  bool get isGranted => this == PermissionStatus.granted;

  bool get canRequest => this == PermissionStatus.notDetermined;
}

/// A snapshot of what the current platform/OS scheduler can actually do,
/// derived from the Wave 0 capability matrix and the live permission state
/// (R-NOTIFY-002, R-NOTIFY-003).
///
/// The scheduling service consults this to decide whether to place reminders,
/// to degrade gracefully, and to surface honest diagnostics in reminder
/// details rather than silently failing.
final class SchedulerCapability {
  const SchedulerCapability({
    required this.permission,
    required this.available,
    required this.exactAlarms,
    required this.actionsSupported,
    this.pendingQuota,
    this.evidenceId,
  });

  /// A fully-capable scheduler with granted permission, used as a test/default
  /// baseline.
  factory SchedulerCapability.fullyCapable() => const SchedulerCapability(
    permission: PermissionStatus.granted,
    available: true,
    exactAlarms: true,
    actionsSupported: true,
  );

  /// The live permission state.
  final PermissionStatus permission;

  /// Whether a notification scheduler is present at all on this platform.
  final bool available;

  /// Whether exact-time alarms are available. When false, reminders still
  /// schedule but may fire inexactly and a degradation diagnostic is surfaced.
  final bool exactAlarms;

  /// Whether interactive notification actions are supported.
  final bool actionsSupported;

  /// The platform's pending-request quota, or null when effectively unbounded.
  final int? pendingQuota;

  /// The capability-matrix evidence id backing this observation, if any.
  final String? evidenceId;

  bool get canSchedule => available && permission.isGranted;
}
