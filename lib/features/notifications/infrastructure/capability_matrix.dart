import 'package:forge/features/notifications/domain/reminder_diagnostics.dart';
import 'package:forge/features/notifications/domain/scheduler_capability.dart';

/// The observed state of a single capability dimension in the Wave 0 matrix
/// (`docs/evidence/scheduling-capability-matrix.v1.json`).
enum CapabilityState { supported, degraded, blocked, unverified }

CapabilityState _stateFromWire(String wire) => switch (wire) {
  'supported' => CapabilityState.supported,
  'degraded' => CapabilityState.degraded,
  'blocked' => CapabilityState.blocked,
  'unverified' => CapabilityState.unverified,
  _ => throw FormatException('Unknown capability state: $wire'),
};

/// One capability observation with its backing evidence id.
final class CapabilityObservation {
  const CapabilityObservation({
    required this.id,
    required this.state,
    required this.evidenceId,
    this.detail,
    this.degradationCode,
  });

  final String id;
  final CapabilityState state;
  final String evidenceId;
  final String? detail;
  final String? degradationCode;
}

/// A typed, minimal reader over the Wave 0 scheduling/capability matrix.
///
/// The reminder scheduling service derives its runtime [SchedulerCapability]
/// and the honest diagnostics it surfaces (R-NOTIFY-003) from this matrix
/// rather than probing plugins directly, so behavior stays deterministic and
/// testable. A `supported` dimension is available; `degraded`/`unverified` are
/// available but flagged; `blocked` is unavailable.
final class SchedulingCapabilityMatrix {
  const SchedulingCapabilityMatrix(this._byPlatform);

  final Map<String, Map<String, CapabilityObservation>> _byPlatform;

  /// Parses the matrix from decoded JSON (the `.v1.json` document shape).
  factory SchedulingCapabilityMatrix.fromJson(Map<String, Object?> json) {
    final List<Object?> targets =
        (json['targets'] as List<Object?>?) ?? const <Object?>[];
    final Map<String, Map<String, CapabilityObservation>> byPlatform =
        <String, Map<String, CapabilityObservation>>{};
    for (final Object? t in targets) {
      final Map<String, Object?> target = t! as Map<String, Object?>;
      final Map<String, Object?> id = target['target']! as Map<String, Object?>;
      final String platform = id['platform']! as String;
      final List<Object?> caps =
          (target['capabilities'] as List<Object?>?) ?? const <Object?>[];
      final Map<String, CapabilityObservation> observations =
          <String, CapabilityObservation>{};
      for (final Object? c in caps) {
        final Map<String, Object?> cap = c! as Map<String, Object?>;
        final String capId = cap['id']! as String;
        observations[capId] = CapabilityObservation(
          id: capId,
          state: _stateFromWire(cap['state']! as String),
          evidenceId: cap['evidenceId'] as String? ?? 'UNKNOWN',
          detail: cap['detail'] as String?,
          degradationCode: cap['degradationCode'] as String?,
        );
      }
      byPlatform[platform] = observations;
    }
    return SchedulingCapabilityMatrix(byPlatform);
  }

  CapabilityObservation? observation(String platform, String capabilityId) =>
      _byPlatform[platform]?[capabilityId];

  /// Derives the runtime scheduler capability for [platform] under the live
  /// [permission] state. Unknown platforms conservatively degrade.
  SchedulerCapability capabilityFor(
    String platform, {
    required PermissionStatus permission,
  }) {
    final Map<String, CapabilityObservation>? caps = _byPlatform[platform];
    if (caps == null) {
      return SchedulerCapability(
        permission: permission,
        available: false,
        exactAlarms: false,
        actionsSupported: false,
        evidenceId: 'PLATFORM-NOT-IN-MATRIX',
      );
    }
    final CapabilityObservation? scheduling = caps['notificationScheduling'];
    final CapabilityObservation? actions = caps['notificationActions'];
    final CapabilityObservation? exact = caps['androidExactAlarm'];
    final bool available =
        scheduling == null || scheduling.state != CapabilityState.blocked;
    return SchedulerCapability(
      permission: permission,
      available: available,
      // Exact alarms only apply on Android; elsewhere treat as available.
      exactAlarms: exact == null
          ? true
          : exact.state == CapabilityState.supported,
      actionsSupported: actions == null
          ? false
          : actions.state == CapabilityState.supported,
      evidenceId: scheduling?.evidenceId,
    );
  }

  /// Diagnostics implied purely by the matrix for [platform] (permission-denied
  /// is added separately from the live permission state).
  List<ReminderDiagnostic> platformDiagnostics(String platform) {
    final Map<String, CapabilityObservation>? caps = _byPlatform[platform];
    if (caps == null) {
      return <ReminderDiagnostic>[
        const ReminderDiagnostic(
          code: ReminderDiagnosticCode.schedulerUnavailable,
          evidenceId: 'PLATFORM-NOT-IN-MATRIX',
          detail: 'Platform absent from the capability matrix.',
        ),
      ];
    }
    final List<ReminderDiagnostic> out = <ReminderDiagnostic>[];
    final CapabilityObservation? actions = caps['notificationActions'];
    if (actions != null && actions.state != CapabilityState.supported) {
      out.add(
        ReminderDiagnostic(
          code: ReminderDiagnosticCode.unsupportedActions,
          evidenceId: actions.evidenceId,
          detail: actions.detail,
        ),
      );
    }
    final CapabilityObservation? exact = caps['androidExactAlarm'];
    if (exact != null && exact.state != CapabilityState.supported) {
      out.add(
        ReminderDiagnostic(
          code: ReminderDiagnosticCode.exactAlarmUnavailable,
          evidenceId: exact.evidenceId,
          detail: exact.detail,
        ),
      );
    }
    return out;
  }
}
