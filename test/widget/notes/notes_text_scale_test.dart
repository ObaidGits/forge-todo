import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'notes_widget_harness.dart';

/// Accessibility reflow tests: at 200% text scale the notes screens still expose
/// every core action, keep tap/label guidelines, and raise no layout-overflow
/// exception (NFR-A11Y-002 responsive completeness, NFR-A11Y-003 text scaling).
///
/// **Validates: Requirements NFR-A11Y-001, NFR-A11Y-002, NFR-A11Y-003**
void main() {
  late NotesWidgetHarness h;

  setUp(() async {
    h = await NotesWidgetHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  testWidgets('notes list reflows at 200% text scale without clipping', (
    WidgetTester tester,
  ) async {
    await h.createNote(title: 'Scaled note');
    await h.pumpApp(tester, textScale: 2);

    // Core actions remain reachable and correctly sized/labeled.
    expect(find.widgetWithText(FilledButton, 'New note'), findsOneWidget);
    expect(find.text('Scaled note'), findsOneWidget);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    // No RenderFlex overflow or other layout exception at 2x.
    expect(tester.takeException(), isNull);
  });

  testWidgets('note editor reflows at 200% text scale without clipping', (
    WidgetTester tester,
  ) async {
    final String id = await h.createNote(
      title: 'Editable at scale',
      body: '# Heading\n\nBody text.',
    );
    await h.pumpApp(tester, initialLocation: '/notes/$id', textScale: 2);

    // The save action and the editable body remain present and usable.
    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Note body'), findsOneWidget);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    expect(tester.takeException(), isNull);
  });
}
