import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'notes_widget_harness.dart';

/// Widget tests for the accessible, adaptive notes list (R-NOTE-002, R-GEN-003,
/// NFR-A11Y-001).
///
/// **Validates: Requirements R-NOTE-001, R-NOTE-002, NFR-A11Y-001**
void main() {
  late NotesWidgetHarness h;

  setUp(() async {
    h = await NotesWidgetHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  testWidgets('renders notes for the active profile', (
    WidgetTester tester,
  ) async {
    await h.createNote(title: 'First note');
    await h.createNote(title: 'Second note');
    await h.pumpApp(tester);

    expect(find.text('First note'), findsOneWidget);
    expect(find.text('Second note'), findsOneWidget);
  });

  testWidgets('an empty view shows an honest empty message', (
    WidgetTester tester,
  ) async {
    await h.pumpApp(tester);
    expect(find.text('No notes yet'), findsOneWidget);
  });

  testWidgets('creating a note opens the editor on the new note', (
    WidgetTester tester,
  ) async {
    await h.pumpApp(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'New note'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Fresh idea');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    // The editor opened: its Save action and body field are present.
    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Note body'), findsOneWidget);
    // And the note is stored.
    expect(
      await h.scalar("SELECT COUNT(*) FROM notes WHERE title = 'Fresh idea'"),
      1,
    );
  });

  testWidgets('pinning a note surfaces it in the Pinned view', (
    WidgetTester tester,
  ) async {
    await h.createNote(title: 'Pin me');
    await h.pumpApp(tester);

    await tester.tap(find.byTooltip('Pin'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, 'Pinned'));
    await tester.pumpAndSettle();
    expect(find.text('Pin me'), findsOneWidget);
  });

  testWidgets('deleting a note offers Undo (R-GEN-003)', (
    WidgetTester tester,
  ) async {
    final String id = await h.createNote(title: 'Delete me');
    await h.pumpApp(tester);

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Note moved to Trash'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, 'Undo'), findsOneWidget);
    expect(
      await h.scalar(
        'SELECT COUNT(*) FROM notes WHERE id = ? AND deleted_at_utc IS NOT NULL',
        <Object?>[id],
      ),
      1,
    );
  });

  testWidgets('the notes list meets tap-target and labeling guidelines', (
    WidgetTester tester,
  ) async {
    await h.createNote(title: 'Accessible note');
    await h.pumpApp(tester);

    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(tester.takeException(), isNull);
  });
}
