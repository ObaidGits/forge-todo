import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/desktop/close_behavior.dart';
import 'package:forge/app/desktop/desktop_settings_store.dart';

/// Records tray control calls so close/tray decisions can be asserted without a
/// real desktop session (the concrete tray binding is a MANUAL-* follow-up).
final class _RecordingTray implements TrayController {
  final List<String> calls = <String>[];

  @override
  Future<void> ensureVisible() async => calls.add('ensureVisible');

  @override
  Future<void> remove() async => calls.add('remove');

  @override
  Future<void> hideWindow() async => calls.add('hideWindow');

  @override
  Future<void> showWindow() async => calls.add('showWindow');

  @override
  Future<void> quit() async => calls.add('quit');
}

void main() {
  group('CloseBehavior', () {
    test('given_unknown_wire_when_fromWire_then_defaults_to_exit', () {
      expect(CloseBehavior.fromWire(null), CloseBehavior.exitApp);
      expect(CloseBehavior.fromWire('nonsense'), CloseBehavior.exitApp);
    });

    test('given_wire_when_fromWire_then_parses', () {
      expect(CloseBehavior.fromWire('tray'), CloseBehavior.minimizeToTray);
      expect(CloseBehavior.fromWire('exit'), CloseBehavior.exitApp);
    });
  });

  group('CloseBehaviorService', () {
    late InMemoryDesktopSettingsStore store;
    late _RecordingTray tray;
    late CloseBehaviorService service;

    setUp(() {
      store = InMemoryDesktopSettingsStore();
      tray = _RecordingTray();
      service = CloseBehaviorService(store: store, tray: tray);
    });

    test('given_no_setting_when_current_then_defaults_to_exit', () async {
      expect(await service.current(), CloseBehavior.exitApp);
    });

    test('given_tray_enabled_when_set_then_persists_and_shows_tray', () async {
      await service.set(CloseBehavior.minimizeToTray);
      expect(await service.current(), CloseBehavior.minimizeToTray);
      expect(tray.calls, contains('ensureVisible'));
    });

    test('given_switch_back_to_quit_when_set_then_tray_removed', () async {
      await service.set(CloseBehavior.minimizeToTray);
      await service.set(CloseBehavior.exitApp);
      expect(await service.current(), CloseBehavior.exitApp);
      expect(tray.calls, contains('remove'));
    });

    test('given_default_when_handleClose_then_quits', () async {
      final CloseAction action = await service.handleClose();
      expect(action, CloseAction.quit);
      expect(tray.calls, <String>['quit']);
    });

    test('given_tray_pref_when_handleClose_then_hides_to_tray', () async {
      await service.set(CloseBehavior.minimizeToTray);
      tray.calls.clear();
      final CloseAction action = await service.handleClose();
      expect(action, CloseAction.hideToTray);
      expect(tray.calls, <String>['hideWindow']);
    });

    test('given_persisted_setting_survives_new_service_instance', () async {
      await service.set(CloseBehavior.minimizeToTray);
      final CloseBehaviorService reopened = CloseBehaviorService(
        store: store,
        tray: _RecordingTray(),
      );
      expect(await reopened.current(), CloseBehavior.minimizeToTray);
    });
  });
}
