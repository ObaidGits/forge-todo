import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/notes/presentation/widgets/markdown_preview.dart';

/// Widget tests for the safe Markdown preview renderer (R-NOTE-001, R-SEC-005,
/// NFR-A11Y-001/003).
///
/// **Validates: Requirements R-NOTE-001, R-SEC-005, NFR-A11Y-001**
void main() {
  Future<void> pumpPreview(
    WidgetTester tester,
    String body, {
    Future<void> Function(String target)? onWikiLink,
    Future<void> Function(String href)? onExternalLink,
    String? notice,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownPreview(
            body: body,
            onWikiLink: onWikiLink,
            onExternalLink: onExternalLink,
            largeDocumentNotice: notice,
            emptyPlaceholder: 'Nothing to preview yet.',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a heading exposes header semantics (NFR-A11Y-001)', (
    WidgetTester tester,
  ) async {
    await pumpPreview(tester, '# Roadmap');
    final SemanticsNode node = tester.getSemantics(find.text('Roadmap'));
    expect(node.flagsCollection.isHeader, isTrue);
  });

  testWidgets('task checkboxes render checked and unchecked states', (
    WidgetTester tester,
  ) async {
    await pumpPreview(tester, '- [x] done\n- [ ] todo');
    expect(find.byIcon(Icons.check_box), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
  });

  testWidgets('a code block scrolls horizontally rather than overflowing', (
    WidgetTester tester,
  ) async {
    await pumpPreview(tester, '```\nvery long code line\n```');
    final Finder scroller = find.ancestor(
      of: find.text('very long code line'),
      matching: find.byType(SingleChildScrollView),
    );
    expect(scroller, findsWidgets);
    final SingleChildScrollView view = tester.widget(scroller.first);
    expect(view.scrollDirection, Axis.horizontal);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unsafe link is neutralized to plain text with no target', (
    WidgetTester tester,
  ) async {
    bool tapped = false;
    await pumpPreview(
      tester,
      '[click](javascript:alert(1))',
      onExternalLink: (_) async => tapped = true,
    );
    // Neutralized: no tappable link is produced at all.
    expect(find.byType(InkWell), findsNothing);
    expect(tapped, isFalse);
  });

  testWidgets('a safe external link routes through the handler on tap', (
    WidgetTester tester,
  ) async {
    String? opened;
    await pumpPreview(
      tester,
      '[site](https://example.com)',
      onExternalLink: (String href) async => opened = href,
    );
    expect(find.widgetWithText(InkWell, 'site'), findsOneWidget);
    await tester.tap(find.widgetWithText(InkWell, 'site'));
    await tester.pumpAndSettle();
    expect(opened, 'https://example.com');
  });

  testWidgets('a wiki-link navigates in-app through the handler', (
    WidgetTester tester,
  ) async {
    String? target;
    await pumpPreview(
      tester,
      'see [[Design Notes]]',
      onWikiLink: (String value) async => target = value,
    );
    expect(find.widgetWithText(InkWell, 'Design Notes'), findsOneWidget);
    await tester.tap(find.widgetWithText(InkWell, 'Design Notes'));
    await tester.pumpAndSettle();
    expect(target, 'Design Notes');
  });

  testWidgets('a very large note shows the bounded-preview notice', (
    WidgetTester tester,
  ) async {
    final String huge = 'a' * (MarkdownPreviewLimits.previewCharacterLimit + 5);
    await pumpPreview(tester, huge, notice: 'Preview is limited.');
    expect(find.text('Preview is limited.'), findsOneWidget);
  });
}
