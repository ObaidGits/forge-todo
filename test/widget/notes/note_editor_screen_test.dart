import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'notes_widget_harness.dart';

/// Widget tests for the accessible Markdown editor + preview (R-NOTE-001,
/// R-NOTE-005, R-SEC-005, NFR-A11Y-001/002/003).
///
/// **Validates: Requirements R-NOTE-001, R-NOTE-005, R-SEC-005, NFR-A11Y-001,
/// NFR-A11Y-002**
void main() {
  late NotesWidgetHarness h;

  setUp(() async {
    h = await NotesWidgetHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  Finder bodyField() => find.widgetWithText(TextField, 'Note body');

  testWidgets('loads the canonical note into edit mode with a toolbar', (
    WidgetTester tester,
  ) async {
    final String id = await h.createNote(title: 'My note', body: 'hello');
    await h.pumpApp(tester, initialLocation: '/notes/$id');

    expect(find.text('My note'), findsOneWidget);
    expect(find.byTooltip('Bold'), findsOneWidget);
    expect(find.byTooltip('Link'), findsOneWidget);
    expect(bodyField(), findsOneWidget);
  });

  testWidgets('the formatting toolbar applies Markdown to the body', (
    WidgetTester tester,
  ) async {
    final String id = await h.createNote(title: 'Fmt', body: '');
    await h.pumpApp(tester, initialLocation: '/notes/$id');

    await tester.tap(find.byTooltip('Bold'));
    await tester.pumpAndSettle();

    expect(find.text('****'), findsOneWidget);
  });

  testWidgets('preview mode renders the safe rendered output', (
    WidgetTester tester,
  ) async {
    final String id = await h.createNote(
      title: 'Preview me',
      body: '# Heading One',
    );
    await h.pumpApp(tester, initialLocation: '/notes/$id');

    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    expect(find.text('Heading One'), findsOneWidget);
    // The raw editor field is not shown in preview mode.
    expect(bodyField(), findsNothing);
  });

  testWidgets('autosave writes the encrypted draft after the debounce', (
    WidgetTester tester,
  ) async {
    final String id = await h.createNote(title: 'Autosave', body: 'v1');
    await h.pumpApp(tester, initialLocation: '/notes/$id');

    await tester.enterText(bodyField(), 'v1 with unsaved edit');
    // Let the debounce window elapse so the draft flushes.
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpAndSettle();

    expect(await h.scalar('SELECT COUNT(*) FROM note_drafts'), 1);
    final Map<String, Object?>? row = await h.firstRow(
      'SELECT base_revision, encrypted_body FROM note_drafts WHERE note_id = ?',
      <Object?>[id],
    );
    expect(row!['base_revision'], 1);
    // Stored body is encrypted at rest, never legible plaintext (R-NOTE-005).
    expect(row['encrypted_body'], isNot(contains('unsaved edit')));
  });

  testWidgets('crash recovery offers the pending draft on open', (
    WidgetTester tester,
  ) async {
    final String id = await h.createNote(title: 'Recover', body: 'original');
    // Simulate a draft left over from a previous session (R-NOTE-005).
    await h.saveDraft(
      noteId: id,
      baseRevision: 1,
      body: 'recovered unsaved text',
      markAwaitingRecovery: true,
    );

    await h.pumpApp(tester, initialLocation: '/notes/$id');

    expect(find.text('Recover unsaved changes?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Recover'));
    await tester.pumpAndSettle();

    expect(find.text('recovered unsaved text'), findsOneWidget);
  });

  testWidgets(
    'discarding recovery keeps the canonical body and drops the draft',
    (WidgetTester tester) async {
      final String id = await h.createNote(title: 'Discard', body: 'canonical');
      await h.saveDraft(
        noteId: id,
        baseRevision: 1,
        body: 'stale draft',
        markAwaitingRecovery: true,
      );

      await h.pumpApp(tester, initialLocation: '/notes/$id');
      await tester.tap(find.widgetWithText(TextButton, 'Discard'));
      await tester.pumpAndSettle();

      expect(find.text('canonical'), findsOneWidget);
      expect(await h.scalar('SELECT COUNT(*) FROM note_drafts'), 0);
    },
  );

  testWidgets('saving commits the body durably and clears the draft', (
    WidgetTester tester,
  ) async {
    final String id = await h.createNote(title: 'Save me', body: 'before');
    await h.pumpApp(tester, initialLocation: '/notes/$id');

    await tester.enterText(bodyField(), 'after save');
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(
      await h.scalar(
        "SELECT COUNT(*) FROM notes WHERE id = ? AND body = 'after save'",
        <Object?>[id],
      ),
      1,
    );
    expect(await h.scalar('SELECT COUNT(*) FROM note_drafts'), 0);
  });

  testWidgets('a disallowed external link is refused by the URI policy', (
    WidgetTester tester,
  ) async {
    final String id = await h.createNote(
      title: 'Links',
      body: '[evil](https://evil.example.net)',
    );
    // Only example.com is allowlisted.
    await h.pumpApp(
      tester,
      initialLocation: '/notes/$id',
      externalHosts: <String>{'example.com'},
    );
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(InkWell, 'evil'));
    await tester.pumpAndSettle();

    // Blocked before any OS handoff.
    expect(h.launchedExternalUris, isEmpty);
    expect(find.textContaining("isn't allowed"), findsOneWidget);
  });

  testWidgets(
    'an allowlisted external link opens after explicit confirmation',
    (WidgetTester tester) async {
      final String id = await h.createNote(
        title: 'Links',
        body: '[site](https://example.com)',
      );
      await h.pumpApp(
        tester,
        initialLocation: '/notes/$id',
        externalHosts: <String>{'example.com'},
      );
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(InkWell, 'site'));
      await tester.pumpAndSettle();
      // Requires an explicit user action (confirmation) before opening.
      expect(find.text('Open external link?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Open'));
      await tester.pumpAndSettle();

      expect(h.launchedExternalUris, hasLength(1));
      expect(h.launchedExternalUris.single.toString(), 'https://example.com');
    },
  );

  testWidgets('the editor meets tap-target and labeling guidelines', (
    WidgetTester tester,
  ) async {
    final String id = await h.createNote(title: 'A11y', body: 'x');
    await h.pumpApp(tester, initialLocation: '/notes/$id');

    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(tester.takeException(), isNull);
  });
}
