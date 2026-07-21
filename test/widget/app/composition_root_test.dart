import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/composition_root.dart';
import 'package:forge/config/app_config.dart';
import 'package:forge/core/domain/clock.dart';

final class _FixedClock implements Clock {
  const _FixedClock();

  @override
  String timezoneId() => 'Asia/Karachi';

  @override
  DateTime utcNow() => DateTime.utc(2026);
}

void main() {
  testWidgets('composition root supplies typed application dependencies', (
    WidgetTester tester,
  ) async {
    const AppConfig config = AppConfig(
      environment: ForgeEnvironment.test,
      releaseChannel: ReleaseChannel.nightly,
      buildRevision: 'composition-test',
    );

    await tester.pumpWidget(
      ForgeCompositionRoot(
        config: config,
        clock: const _FixedClock(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? child) {
              final AppConfig resolved = ref.watch(appConfigProvider);
              final String timezone = ref.watch(clockProvider).timezoneId();
              return Text('${resolved.buildRevision}:$timezone');
            },
          ),
        ),
      ),
    );

    expect(find.text('composition-test:Asia/Karachi'), findsOneWidget);
  });
}
