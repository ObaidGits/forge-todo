/// Registers or removes Forge from the OS "launch at login" list.
///
/// This is the integration boundary over `launch_at_startup`. The real binding
/// touches the Windows registry / `~/.config/autostart` and is guarded by
/// platform; the abstraction keeps the plugin out of mobile/test builds and
/// lets the settings toggle be unit-tested with a fake.
abstract interface class AutostartController {
  /// Whether Forge is currently registered to launch at login.
  Future<bool> isEnabled();

  /// Registers Forge to launch at login.
  Future<void> enable();

  /// Removes Forge from the login autostart list.
  Future<void> disable();
}

/// A no-op autostart controller used on mobile, in tests, and headless. Records
/// the requested state so the settings orchestration can be asserted.
final class NoopAutostartController implements AutostartController {
  NoopAutostartController({this.enabled = false});

  /// The recorded autostart state.
  bool enabled;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<void> enable() async => enabled = true;

  @override
  Future<void> disable() async => enabled = false;
}
