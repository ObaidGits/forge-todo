import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/ui/forge_motion.dart';

void main() {
  Widget host({required bool disableAnimations, required Widget child}) {
    return MaterialApp(
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: disableAnimations),
          child: child,
        ),
      ),
    );
  }

  testWidgets('reduceMotion mirrors the platform disable-animations setting', (
    WidgetTester tester,
  ) async {
    late bool observed;
    await tester.pumpWidget(
      host(
        disableAnimations: true,
        child: Builder(
          builder: (BuildContext context) {
            observed = ForgeMotion.reduceMotion(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(observed, isTrue);

    await tester.pumpWidget(
      host(
        disableAnimations: false,
        child: Builder(
          builder: (BuildContext context) {
            observed = ForgeMotion.reduceMotion(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(observed, isFalse);
  });

  testWidgets('duration collapses to zero only when reduce motion is on', (
    WidgetTester tester,
  ) async {
    const Duration base = Duration(milliseconds: 200);
    late Duration reduced;
    late Duration normal;
    await tester.pumpWidget(
      host(
        disableAnimations: true,
        child: Builder(
          builder: (BuildContext context) {
            reduced = ForgeMotion.duration(context, base);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpWidget(
      host(
        disableAnimations: false,
        child: Builder(
          builder: (BuildContext context) {
            normal = ForgeMotion.duration(context, base);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(reduced, Duration.zero);
    expect(normal, base);
  });

  testWidgets('ForgeAnimatedSwitcher skips the switcher under reduce motion', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        disableAnimations: true,
        child: const ForgeAnimatedSwitcher(child: Text('hello')),
      ),
    );
    expect(find.byType(AnimatedSwitcher), findsNothing);
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('ForgeAnimatedSwitcher animates when motion is allowed', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        disableAnimations: false,
        child: const ForgeAnimatedSwitcher(child: Text('hello')),
      ),
    );
    expect(find.byType(AnimatedSwitcher), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
  });
}
