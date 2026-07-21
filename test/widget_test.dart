import 'package:flutter_test/flutter_test.dart';
import 'package:forge/config/app_config.dart';
import 'package:forge/forge_app.dart';

void main() {
  testWidgets('renders the localized production scaffold', (
    WidgetTester tester,
  ) async {
    const AppConfig config = AppConfig(
      environment: ForgeEnvironment.production,
      releaseChannel: ReleaseChannel.nightly,
      buildRevision: 'test-revision',
    );

    await tester.pumpWidget(const ForgeApp(config: config));
    await tester.pumpAndSettle();

    // The production scaffold opens on the localized Today screen (R-HOME-001):
    // its heading and the always-available quick capture label render.
    expect(find.text('Today'), findsWidgets);
    expect(find.text('Add a task'), findsOneWidget);
  });
}
