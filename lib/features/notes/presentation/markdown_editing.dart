import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The set of Markdown formatting commands the editor toolbar and keyboard
/// shortcuts expose (R-NOTE-001). Each command is a pure text transformation so
/// the toolbar and the keyboard bindings share one tested implementation.
enum MarkdownCommand {
  /// Wrap the selection in `**strong**`.
  bold,

  /// Wrap the selection in `*emphasis*`.
  italic,

  /// Toggle a `# ` heading prefix on the selected lines.
  heading,

  /// Toggle a `- ` bullet prefix on the selected lines.
  bulletList,

  /// Toggle a `- [ ] ` task checkbox prefix on the selected lines.
  checkbox,

  /// Wrap the selection in an inline `` `code` `` span.
  code,

  /// Turn the selection into a `[label](url)` link.
  link,
}

/// An immutable text + selection pair, mirroring the parts of a
/// [TextEditingValue] the formatting transforms touch.
final class MarkdownEditState {
  const MarkdownEditState({required this.text, required this.selection});

  MarkdownEditState.collapsed(this.text)
    : selection = TextSelection.collapsed(offset: text.length);

  final String text;
  final TextSelection selection;

  TextEditingValue toValue() =>
      TextEditingValue(text: text, selection: selection);

  static MarkdownEditState fromValue(TextEditingValue value) =>
      MarkdownEditState(
        text: value.text,
        // A value with no valid selection (offset -1) edits at the end.
        selection: value.selection.isValid
            ? value.selection
            : TextSelection.collapsed(offset: value.text.length),
      );
}

/// Pure Markdown formatting transforms shared by the toolbar and keyboard
/// commands (R-NOTE-001). Every method returns a new [MarkdownEditState] and
/// never mutates its input, which keeps the transforms trivially testable
/// without a widget tree.
abstract final class MarkdownEditing {
  /// Applies [command] to [state], returning the resulting text and selection.
  /// [linkUrl] supplies the target for [MarkdownCommand.link]; it is ignored by
  /// the other commands.
  static MarkdownEditState apply(
    MarkdownCommand command,
    MarkdownEditState state, {
    String linkUrl = '',
  }) {
    return switch (command) {
      MarkdownCommand.bold => _wrap(state, '**'),
      MarkdownCommand.italic => _wrap(state, '*'),
      MarkdownCommand.code => _wrap(state, '`'),
      MarkdownCommand.heading => _togglePrefix(state, '# '),
      MarkdownCommand.bulletList => _togglePrefix(state, '- '),
      MarkdownCommand.checkbox => _togglePrefix(state, '- [ ] '),
      MarkdownCommand.link => _link(state, linkUrl),
    };
  }

  /// Wraps the current selection with [token] on both sides. When the selection
  /// is already wrapped, the tokens are removed (a toggle). With an empty
  /// selection the tokens are inserted and the caret is placed between them.
  static MarkdownEditState _wrap(MarkdownEditState state, String token) {
    final TextSelection selection = _clampedSelection(state);
    final String text = state.text;
    final int start = selection.start;
    final int end = selection.end;
    final String selected = text.substring(start, end);

    final bool alreadyWrapped =
        start >= token.length &&
        end + token.length <= text.length &&
        text.substring(start - token.length, start) == token &&
        text.substring(end, end + token.length) == token;

    if (alreadyWrapped) {
      final String next =
          text.substring(0, start - token.length) +
          selected +
          text.substring(end + token.length);
      return MarkdownEditState(
        text: next,
        selection: TextSelection(
          baseOffset: start - token.length,
          extentOffset: end - token.length,
        ),
      );
    }

    final String next =
        text.substring(0, start) +
        token +
        selected +
        token +
        text.substring(end);
    if (selected.isEmpty) {
      final int caret = start + token.length;
      return MarkdownEditState(
        text: next,
        selection: TextSelection.collapsed(offset: caret),
      );
    }
    return MarkdownEditState(
      text: next,
      selection: TextSelection(
        baseOffset: start + token.length,
        extentOffset: end + token.length,
      ),
    );
  }

  /// Toggles a line [prefix] on every line the selection touches. If every
  /// affected line already begins with [prefix] it is removed, otherwise it is
  /// added — matching the familiar behavior of list/heading toolbar buttons.
  static MarkdownEditState _togglePrefix(
    MarkdownEditState state,
    String prefix,
  ) {
    final TextSelection selection = _clampedSelection(state);
    final String text = state.text;
    final int lineStart = _lineStart(text, selection.start);
    final int lineEnd = _lineEnd(text, selection.end);
    final String region = text.substring(lineStart, lineEnd);
    final List<String> lines = region.split('\n');

    final bool allPrefixed = lines.every(
      (String line) => line.startsWith(prefix),
    );
    final List<String> updated = <String>[
      for (final String line in lines)
        allPrefixed ? line.substring(prefix.length) : '$prefix$line',
    ];
    final String replacement = updated.join('\n');
    final String next =
        text.substring(0, lineStart) + replacement + text.substring(lineEnd);
    return MarkdownEditState(
      text: next,
      selection: TextSelection(
        baseOffset: lineStart,
        extentOffset: lineStart + replacement.length,
      ),
    );
  }

  /// Turns the selection into `[label](url)`. With an empty selection an empty
  /// label placeholder is inserted and selected so the user can type it.
  static MarkdownEditState _link(MarkdownEditState state, String url) {
    final TextSelection selection = _clampedSelection(state);
    final String text = state.text;
    final int start = selection.start;
    final int end = selection.end;
    final String label = text.substring(start, end);
    final String next =
        '${text.substring(0, start)}[$label]($url)${text.substring(end)}';
    if (label.isEmpty) {
      // Select the empty label slot (right after the opening bracket).
      return MarkdownEditState(
        text: next,
        selection: TextSelection.collapsed(offset: start + 1),
      );
    }
    // Place the caret inside the (url) so the target can be typed/replaced.
    final int urlStart = start + 1 + label.length + 2;
    return MarkdownEditState(
      text: next,
      selection: TextSelection(
        baseOffset: urlStart,
        extentOffset: urlStart + url.length,
      ),
    );
  }

  static TextSelection _clampedSelection(MarkdownEditState state) {
    final int length = state.text.length;
    if (!state.selection.isValid) {
      return TextSelection.collapsed(offset: length);
    }
    final int start = state.selection.start.clamp(0, length);
    final int end = state.selection.end.clamp(0, length);
    return TextSelection(baseOffset: start, extentOffset: end);
  }

  static int _lineStart(String text, int offset) {
    if (offset <= 0) {
      return 0;
    }
    final int newline = text.lastIndexOf('\n', offset - 1);
    return newline == -1 ? 0 : newline + 1;
  }

  static int _lineEnd(String text, int offset) {
    final int newline = text.indexOf('\n', offset);
    return newline == -1 ? text.length : newline;
  }
}

/// Maps a keyboard [SingleActivator] set to Markdown commands (ux-design §4:
/// desktop shortcuts, remappable). The editor wires these through
/// `CallbackShortcuts` so every toolbar action has a keyboard equivalent
/// (NFR-A11Y-001).
abstract final class MarkdownShortcuts {
  static Map<ShortcutActivator, MarkdownCommand> bindings() =>
      <ShortcutActivator, MarkdownCommand>{
        const SingleActivator(LogicalKeyboardKey.keyB, control: true):
            MarkdownCommand.bold,
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true):
            MarkdownCommand.bold,
        const SingleActivator(LogicalKeyboardKey.keyI, control: true):
            MarkdownCommand.italic,
        const SingleActivator(LogicalKeyboardKey.keyI, meta: true):
            MarkdownCommand.italic,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            MarkdownCommand.link,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            MarkdownCommand.link,
        const SingleActivator(LogicalKeyboardKey.keyE, control: true):
            MarkdownCommand.code,
        const SingleActivator(LogicalKeyboardKey.keyE, meta: true):
            MarkdownCommand.code,
      };
}
