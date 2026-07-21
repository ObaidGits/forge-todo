/// Capability-gated distraction messaging (R-FOCUS-006).
///
/// Forge SHALL NOT claim to block distractions unless an independently
/// permissioned platform capability is actually active. This pure policy maps
/// the current capability state to a safe, honest message key so no screen can
/// accidentally over-promise. When the capability is inactive the copy only
/// ever offers *minimize distractions* framing (e.g. do-not-disturb reminders);
/// only when the capability is active may the copy state that distractions are
/// blocked.
abstract final class DistractionCopy {
  /// Message key shown when a blocking capability is active and Forge may
  /// truthfully claim distractions are being blocked.
  static const String blockingActiveKey = 'focus.distraction.blocking_active';

  /// Message key shown when no blocking capability is active. It never claims
  /// blocking — it only encourages the user to minimize distractions.
  static const String blockingUnavailableKey =
      'focus.distraction.minimize_only';

  /// Resolves the message key for the given capability state (R-FOCUS-006).
  static String messageKey({required bool blockingCapabilityActive}) =>
      blockingCapabilityActive ? blockingActiveKey : blockingUnavailableKey;

  /// Whether Forge is permitted to claim distraction blocking. This is true
  /// only when an independently permissioned capability is active; it is the
  /// single gate every distraction claim must pass (R-FOCUS-006).
  static bool mayClaimBlocking({required bool blockingCapabilityActive}) =>
      blockingCapabilityActive;
}
