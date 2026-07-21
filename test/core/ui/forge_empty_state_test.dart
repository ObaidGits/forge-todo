import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/ui/forge_empty_state.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

  testWidgets('renders title and body and exposes the title as a heading', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      const ForgeEmptyState(
        title: 'Nothing scheduled yet',
        body: 'Capture a task to start your day.',
      ),
    );

    expect(find.text('Nothing scheduled yet'), findsOneWidget);
    expect(find.text('Capture a task to start your day.'), findsOneWidget);

    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is Semantics && (widget.properties.header ?? false),
      ),
      findsOneWidget,
    );
  });

  testWidgets('decorative icon is hidden from assistive technology', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await pump(
      tester,
      const ForgeEmptyState(
        title: 'Your inbox is clear',
        body: 'Nothing to triage.',
        icon: Icons.inbox_outlined,
      ),
    );

    expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Your inbox is clear')), findsWidgets);
    handle.dispose();
  });

  testWidgets('optional action stays an accessible tap target', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      ForgeEmptyState(
        title: 'No goals yet',
        body: 'Add one to connect daily work to an outcome.',
        action: FilledButton(onPressed: () {}, child: const Text('New goal')),
      ),
    );

    expect(find.text('New goal'), findsOneWidget);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  });

  testWidgets('compact layout renders without a scroll view', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      const ForgeEmptyState(
        title: 'Trash is empty',
        body: 'Deleted items appear here.',
        compact: true,
      ),
    );

    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(find.text('Trash is empty'), findsOneWidget);
  });
}
