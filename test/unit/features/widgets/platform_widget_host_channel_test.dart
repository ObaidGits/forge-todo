/// Platform widget host channel tests (R-WIDGET-001, R-WIDGET-002).
///
/// The platform channel is the production replacement for the in-memory host
/// channel. These tests intercept the method channel the native host listens on
/// and prove that:
///
///   * `publish` sends the canonical snapshot bytes (the exact bytes the native
///     container will decode) under the surface's wire name;
///   * the payload decodes back to an equal snapshot (native <-> Dart codec
///     agreement);
///   * `clear` and `publishSecret` send the agreed method/args.
///
/// Real native storage + rendering are the device/platform follow-ups (11.4).
///
/// **Validates: Requirements R-WIDGET-001, R-WIDGET-002**
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/widgets/application/widget_snapshot_builder.dart';
import 'package:forge/features/widgets/domain/widget_platform_contract.dart';
import 'package:forge/features/widgets/domain/widget_snapshot.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';
import 'package:forge/features/widgets/infrastructure/platform_widget_host_channel.dart';

import '../../../helpers/helpers.dart';

EvidenceMetadata _evidence(String suffix, List<String> requirements) =>
    EvidenceMetadata(
      evidenceId: EvidenceId('WIDGET-HOSTCHANNEL-$suffix'),
      releaseTag: ReleaseTag.v1,
      taskId: SpecTaskId('11.2'),
      requirements: <RequirementId>[
        for (final String requirement in requirements)
          RequirementId(requirement),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MethodChannel channel = const MethodChannel(
    WidgetPlatformContract.hostChannel,
  );
  final List<MethodCall> calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  final WidgetSnapshotBuilder builder = WidgetSnapshotBuilder(
    clock: FakeClock(initialUtc: DateTime.utc(2024, 6, 1, 12)),
  );

  WidgetSnapshot todaySnapshot({bool contentVisible = true}) => builder.build(
    surface: WidgetSurface.todayTasks,
    profileId: ProfileId('profile-1'),
    items: <WidgetSnapshotItem>[
      WidgetSnapshotItem(id: 'task-1', title: 'Ship widgets'),
      WidgetSnapshotItem(id: 'task-2', title: 'Write tests'),
    ],
    contentVisible: contentVisible,
  );

  testWithEvidence(
    _evidence('PUBLISH-CANONICAL', <String>['R-WIDGET-002']),
    'publish sends the canonical payload the native container decodes',
    () async {
      final PlatformWidgetHostChannel host = PlatformWidgetHostChannel(
        channel: channel,
      );
      final WidgetSnapshot snapshot = todaySnapshot();
      await host.publish(snapshot);

      expect(calls, hasLength(1));
      expect(calls.single.method, WidgetPlatformContract.methodPublish);
      final Map<Object?, Object?> args =
          calls.single.arguments as Map<Object?, Object?>;
      expect(args[WidgetPlatformContract.paramSurface], 'today_tasks');

      final String payload = args['payload']! as String;
      expect(payload, WidgetSnapshotCodec.encode(snapshot));
      // Native container agreement: the payload decodes to an equal snapshot.
      expect(WidgetSnapshotCodec.decode(payload), snapshot);
    },
  );

  testWithEvidence(
    _evidence('PUBLISH-REDACTED', <String>['R-WIDGET-002']),
    'a redacted snapshot still transmits with no items for the container',
    () async {
      final PlatformWidgetHostChannel host = PlatformWidgetHostChannel(
        channel: channel,
      );
      await host.publish(todaySnapshot(contentVisible: false));

      final Map<Object?, Object?> args =
          calls.single.arguments as Map<Object?, Object?>;
      final WidgetSnapshot decoded = WidgetSnapshotCodec.decode(
        args['payload']! as String,
      )!;
      expect(decoded.redacted, isTrue);
      expect(decoded.items, isEmpty);
    },
  );

  testWithEvidence(
    _evidence('CLEAR', <String>['R-WIDGET-001']),
    'clear sends the surface wire name to the native host',
    () async {
      final PlatformWidgetHostChannel host = PlatformWidgetHostChannel(
        channel: channel,
      );
      await host.clear(WidgetSurface.quickNote);

      expect(calls.single.method, WidgetPlatformContract.methodClear);
      final Map<Object?, Object?> args =
          calls.single.arguments as Map<Object?, Object?>;
      expect(args[WidgetPlatformContract.paramSurface], 'quick_note');
    },
  );

  testWithEvidence(
    _evidence('PUBLISH-SECRET', <String>['R-WIDGET-001']),
    'publishSecret sends the shared bridge secret to the native host',
    () async {
      final PlatformWidgetHostChannel host = PlatformWidgetHostChannel(
        channel: channel,
      );
      await host.publishSecret('shared-bridge-secret-value');

      expect(calls.single.method, WidgetPlatformContract.methodPublishSecret);
      final Map<Object?, Object?> args =
          calls.single.arguments as Map<Object?, Object?>;
      expect(args['secret'], 'shared-bridge-secret-value');
    },
  );
}
