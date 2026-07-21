import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/notes/presentation/markdown_editing.dart';

/// Unit and generative tests for the pure Markdown formatting transforms shared
/// by the toolbar and keyboard commands (R-NOTE-001).
///
/// **Validates: Requirements R-NOTE-001**
void main() {
  MarkdownEditState stateWith(String text, int start, int end) =>
      MarkdownEditState(
        text: text,
        selection: TextSelection(baseOffset: start, extentOffset: end),
      );

  group('wrap commands (bold/italic/code)', () {
    test('bold wraps the selection and keeps it selected', () {
      final MarkdownEditState result = MarkdownEditing.apply(
        MarkdownCommand.bold,
        stateWith('hello world', 6, 11),
      );
      expect(result.text, 'hello **world**');
      expect(result.selection.textInside(result.text), 'world');
    });

    test(
      'bold on an empty selection inserts markers and centers the caret',
      () {
        final MarkdownEditState result = MarkdownEditing.apply(
          MarkdownCommand.bold,
          stateWith('', 0, 0),
        );
        expect(result.text, '****');
        expect(result.selection.baseOffset, 2);
        expect(result.selection.isCollapsed, isTrue);
      },
    );

    test('bold toggles off when the selection is already wrapped', () {
      // "hello **world**" with "world" selected between the markers.
      final MarkdownEditState result = MarkdownEditing.apply(
        MarkdownCommand.bold,
        stateWith('hello **world**', 8, 13),
      );
      expect(result.text, 'hello world');
      expect(result.selection.textInside(result.text), 'world');
    });

    test('italic uses a single asterisk', () {
      final MarkdownEditState result = MarkdownEditing.apply(
        MarkdownCommand.italic,
        stateWith('word', 0, 4),
      );
      expect(result.text, '*word*');
    });

    test('code uses a backtick', () {
      final MarkdownEditState result = MarkdownEditing.apply(
        MarkdownCommand.code,
        stateWith('x', 0, 1),
      );
      expect(result.text, '`x`');
    });
  });

  group('line-prefix commands (heading/list/checkbox)', () {
    test('heading prefixes the current line', () {
      final MarkdownEditState result = MarkdownEditing.apply(
        MarkdownCommand.heading,
        stateWith('Title', 0, 0),
      );
      expect(result.text, '# Title');
    });

    test('bullet list toggles across all selected lines', () {
      final MarkdownEditState result = MarkdownEditing.apply(
        MarkdownCommand.bulletList,
        stateWith('one\ntwo', 0, 7),
      );
      expect(result.text, '- one\n- two');
    });

    test('checkbox prefixes with a task marker and toggles off again', () {
      final MarkdownEditState added = MarkdownEditing.apply(
        MarkdownCommand.checkbox,
        stateWith('do it', 0, 0),
      );
      expect(added.text, '- [ ] do it');

      final MarkdownEditState removed = MarkdownEditing.apply(
        MarkdownCommand.checkbox,
        MarkdownEditState(text: added.text, selection: added.selection),
      );
      expect(removed.text, 'do it');
    });
  });

  group('link command', () {
    test('link wraps the selection as [label](url)', () {
      final MarkdownEditState result = MarkdownEditing.apply(
        MarkdownCommand.link,
        stateWith('Forge', 0, 5),
        linkUrl: 'https://example.com',
      );
      expect(result.text, '[Forge](https://example.com)');
    });

    test('link on an empty selection leaves an editable label slot', () {
      final MarkdownEditState result = MarkdownEditing.apply(
        MarkdownCommand.link,
        stateWith('', 0, 0),
        linkUrl: 'https://example.com',
      );
      expect(result.text, '[](https://example.com)');
    });
  });

  group('generative invariants', () {
    test('toggling a wrap command twice is the identity transform', () {
      final Random random = Random(20240615);
      const String alphabet = 'ab cd\nef';
      for (int i = 0; i < 400; i += 1) {
        final int length = random.nextInt(12);
        final StringBuffer buffer = StringBuffer();
        for (int c = 0; c < length; c += 1) {
          buffer.write(alphabet[random.nextInt(alphabet.length)]);
        }
        final String text = buffer.toString();
        final int a = text.isEmpty ? 0 : random.nextInt(text.length + 1);
        final int b = text.isEmpty ? 0 : random.nextInt(text.length + 1);
        final MarkdownEditState start = MarkdownEditState(
          text: text,
          selection: TextSelection(
            baseOffset: min(a, b),
            extentOffset: max(a, b),
          ),
        );
        final MarkdownCommand command = <MarkdownCommand>[
          MarkdownCommand.bold,
          MarkdownCommand.italic,
          MarkdownCommand.code,
        ][random.nextInt(3)];

        final MarkdownEditState once = MarkdownEditing.apply(command, start);
        final MarkdownEditState twice = MarkdownEditing.apply(command, once);
        expect(
          twice.text,
          text,
          reason:
              'command=$command text="$text" '
              'sel=${start.selection.start}..${start.selection.end}',
        );
      }
    });

    test('the selected substring survives a wrap', () {
      final Random random = Random(7);
      const String alphabet = 'xyz  ';
      for (int i = 0; i < 300; i += 1) {
        final int length = 1 + random.nextInt(10);
        final StringBuffer buffer = StringBuffer();
        for (int c = 0; c < length; c += 1) {
          buffer.write(alphabet[random.nextInt(alphabet.length)]);
        }
        final String text = buffer.toString();
        final int a = random.nextInt(text.length + 1);
        final int b = random.nextInt(text.length + 1);
        final int start = min(a, b);
        final int end = max(a, b);
        final String selected = text.substring(start, end);
        final MarkdownEditState result = MarkdownEditing.apply(
          MarkdownCommand.bold,
          MarkdownEditState(
            text: text,
            selection: TextSelection(baseOffset: start, extentOffset: end),
          ),
        );
        expect(result.selection.textInside(result.text), selected);
      }
    });
  });
}
