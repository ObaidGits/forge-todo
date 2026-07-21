/// The app-lock presentation/session gate and privacy controls (R-SEC-003).
///
/// The app lock is NOT the encryption boundary — the [KeyVault] is. This gate
/// only decides whether the current interactive session may reveal content and
/// whether background work may proceed. Background access is permitted only
/// when the underlying key can be released without user presence; otherwise the
/// work skips safely and reconciles after the next unlock.
library;

import 'package:forge/core/security/key_vault.dart';
import 'package:forge/core/security/key_vault_ports.dart';

/// Session gate status.
enum AppLockStatus {
  /// No app lock is configured; the session is always open.
  notConfigured,

  /// A lock is configured and the current session is authenticated.
  unlocked,

  /// A lock is configured and the session must be re-authenticated.
  locked,
}

/// User privacy controls for surfaces that can leak content while locked.
final class PrivacyControls {
  const PrivacyControls({
    this.obscureAppSwitcherSnapshot = true,
    this.hideNotificationPreviews = true,
    this.hideWidgetPreviews = true,
  });

  /// Blur/replace the recent-apps (app switcher) snapshot.
  final bool obscureAppSwitcherSnapshot;

  /// Redact notification content while the session is locked.
  final bool hideNotificationPreviews;

  /// Redact widget snapshot content on locked surfaces.
  final bool hideWidgetPreviews;

  PrivacyControls copyWith({
    bool? obscureAppSwitcherSnapshot,
    bool? hideNotificationPreviews,
    bool? hideWidgetPreviews,
  }) {
    return PrivacyControls(
      obscureAppSwitcherSnapshot:
          obscureAppSwitcherSnapshot ?? this.obscureAppSwitcherSnapshot,
      hideNotificationPreviews:
          hideNotificationPreviews ?? this.hideNotificationPreviews,
      hideWidgetPreviews: hideWidgetPreviews ?? this.hideWidgetPreviews,
    );
  }
}

typedef MonotonicElapsed = Duration Function();

/// A deterministic, testable presentation/session lock gate.
///
/// Time is injected via [elapsed] (a monotonic source) so idle auto-lock is
/// testable without wall-clock flakiness. All transitions are pure state
/// changes; the gate performs no key release itself.
final class AppLockGate {
  AppLockGate({
    required this.elapsed,
    this.autoLockAfter = const Duration(minutes: 1),
    bool configured = false,
    PrivacyControls privacy = const PrivacyControls(),
  }) : _status = configured
           ? AppLockStatus.locked
           : AppLockStatus.notConfigured {
    _privacy = privacy;
  }

  /// Monotonic elapsed-time source used to evaluate idle auto-lock.
  final MonotonicElapsed elapsed;

  /// Idle interval after backgrounding before the session auto-locks.
  final Duration autoLockAfter;

  AppLockStatus _status;
  PrivacyControls _privacy = const PrivacyControls();
  Duration? _backgroundedAt;

  AppLockStatus get status => _status;

  PrivacyControls get privacy => _privacy;

  bool get isConfigured => _status != AppLockStatus.notConfigured;

  /// Whether interactive content may be revealed right now.
  bool get isContentVisible => _status != AppLockStatus.locked;

  /// Enables the lock. The session starts locked and must be unlocked once.
  void configure({PrivacyControls? privacy}) {
    if (privacy != null) {
      _privacy = privacy;
    }
    if (_status == AppLockStatus.notConfigured) {
      _status = AppLockStatus.locked;
    }
  }

  /// Disables the lock entirely (returns to an always-open session).
  void disable() {
    _status = AppLockStatus.notConfigured;
    _backgroundedAt = null;
  }

  void updatePrivacy(PrivacyControls privacy) {
    _privacy = privacy;
  }

  /// Marks the current session authenticated. Only meaningful when configured;
  /// callers unlock the gate after the [KeyVault] has released the key.
  void markUnlocked() {
    if (_status == AppLockStatus.notConfigured) {
      return;
    }
    _status = AppLockStatus.unlocked;
    _backgroundedAt = null;
  }

  /// Explicitly locks the session (user action or key lock).
  void lock() {
    if (_status == AppLockStatus.notConfigured) {
      return;
    }
    _status = AppLockStatus.locked;
    _backgroundedAt = null;
  }

  /// Records that the app entered the background. Auto-lock is evaluated on the
  /// next [onForegrounded].
  void onBackgrounded() {
    if (_status == AppLockStatus.unlocked) {
      _backgroundedAt = elapsed();
    }
  }

  /// Re-evaluates the session on returning to the foreground. Locks if the idle
  /// interval elapsed while backgrounded.
  void onForegrounded() {
    final Duration? since = _backgroundedAt;
    if (_status != AppLockStatus.unlocked || since == null) {
      return;
    }
    if (elapsed() - since >= autoLockAfter) {
      _status = AppLockStatus.locked;
    }
    _backgroundedAt = null;
  }

  /// Whether a preview surface may show real content, combining the session
  /// state with the relevant privacy control.
  bool notificationPreviewVisible() =>
      isContentVisible || !_privacy.hideNotificationPreviews;

  bool widgetPreviewVisible() =>
      isContentVisible || !_privacy.hideWidgetPreviews;

  bool appSwitcherContentVisible() =>
      isContentVisible && !_privacy.obscureAppSwitcherSnapshot;
}

/// Decides whether background/headless work may access the database without an
/// interactive unlock, based on the key's protection.
///
/// This mirrors [KeyVaultMachine] headless-release semantics for callers that
/// only know the protection kind (e.g. a background reconciler deciding whether
/// to run before touching the vault).
bool backgroundAccessAllowed(VaultProtection protection) =>
    !protection.requiresUserPresence;
