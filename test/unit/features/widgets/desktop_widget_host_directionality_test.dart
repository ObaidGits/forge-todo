import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/widgets/desktop/desktop_widget_host.dart';

/// Regression: on desktop the [DesktopWidgetHost]'s `Stack` sits at the very top
/// of the widget tree — above the child `MaterialApp`s that each establish their
/// own `Directionality`. A bare `Stack` defaults to
/// `AlignmentDirectional.topStart`, whose `.resolve()` null-checks the ambient
/// `TextDirection` and throws at first-frame layout when none exists. That crash
/// broke every frame of the release desktop build (blank/unrenderable UI).
///
/// The host must therefore lay out with NO ambient `Directionality`.
void main() {
  testWidgets(
    'DesktopWidgetHost lays out at the tree root without an ambient '
    'Directionality (no AlignmentDirectional null-check crash)',
    (WidgetTester tester) async {
      // Mount the host directly — pumpWidget provides a View/pipeline owner but
      // deliberately NO Directionality, exactly mirroring the desktop root tree
      // (ProviderScope > DesktopShellBinder > DesktopWidgetHost) where the child
      // fullApp supplies its own Directionality below this Stack.
      await tester.pumpWidget(
        const ProviderScope(
          child: DesktopWidgetHost(
            fullApp: SizedBox.shrink(),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(DesktopWidgetHost), findsOneWidget);
    },
  );
}
