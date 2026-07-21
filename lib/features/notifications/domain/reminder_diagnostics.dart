/// A visible reason a reminder could not be scheduled exactly as requested
/// (R-NOTIFY-003). Every code maps to a stable, presentation-safe message key
/// and, where platform-sourced, a capability-matrix evidence id.
enum ReminderDiagnosticCode {
  /// The user denied notification permission.
  permissionDenied,

  /// The platform pending-notification quota was exceeded and the horizon was
  /// truncated to the earliest reminders.
  osQuotaExceeded,

  /// Exact alarms are unavailable; reminders may fire inexactly.
  exactAlarmUnavailable,

  /// Interactive notification actions are not supported on this platform.
  unsupportedActions,

  /// The OS scheduler rejected a request.
  schedulerFailure,

  /// The reminder's category is disabled in settings.
  categoryDisabled,

  /// No notification scheduler is available on this platform.
  schedulerUnavailable;

  String get wire => name;

  /// Stable presentation message key (design §15).
  String get safeMessageKey => 'reminder.diagnostic.$name';
}

/// A single diagnostic finding produced by reconciliation and surfaced in
/// reminder details (R-NOTIFY-003).
final class ReminderDiagnostic {
  const ReminderDiagnostic({
    required this.code,
    this.detail,
    this.evidenceId,
    this.reminderId,
  });

  final ReminderDiagnosticCode code;

  /// A short, redacted explanation (never user content).
  final String? detail;

  /// The capability-matrix evidence id for platform-sourced diagnostics.
  final String? evidenceId;

  /// The specific reminder affected, or null for a scheduler-wide diagnostic.
  final String? reminderId;

  @override
  bool operator ==(Object other) =>
      other is ReminderDiagnostic &&
      other.code == code &&
      other.detail == detail &&
      other.evidenceId == evidenceId &&
      other.reminderId == reminderId;

  @override
  int get hashCode => Object.hash(code, detail, evidenceId, reminderId);

  @override
  String toString() =>
      'ReminderDiagnostic(${code.name}, reminder: $reminderId, '
      'evidence: $evidenceId)';
}
