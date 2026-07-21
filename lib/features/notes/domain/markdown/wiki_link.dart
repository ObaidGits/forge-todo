/// `[[wiki-link]]` extraction from a note body (R-NOTE-003, R-NOTE-004).
///
/// Task 5.1 owns the transactional maintenance of the outgoing link set: when a
/// note body is written, its `[[Target]]` / `[[Target|Label]]` references are
/// extracted with their exact source positions so link rows can be maintained
/// in the same commit as the note write. Resolution to concrete target note ids
/// (and the explicit ambiguity prompt) is layered on in task 5.2; this
/// extractor deliberately reports only the parsed references and their ranges.
library;

/// A single outgoing wiki-link reference parsed from a note body.
final class WikiLinkRef {
  const WikiLinkRef({
    required this.target,
    required this.label,
    required this.start,
    required this.end,
  });

  /// The referenced note title text (trimmed).
  final String target;

  /// The visible label, equal to [target] when no `|alias` was supplied.
  final String label;

  /// UTF-16 code-unit offsets of the full `[[...]]` span in the source body.
  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is WikiLinkRef &&
      other.target == target &&
      other.label == label &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(target, label, start, end);
}

abstract final class WikiLink {
  /// Extracts every well-formed `[[...]]` reference from [body], in source
  /// order. References inside inline or fenced code are ignored because code is
  /// literal (a link inside code is not navigable). An empty target
  /// (`[[]]` or `[[ | x ]]`) is skipped.
  static List<WikiLinkRef> extract(String body) {
    final List<WikiLinkRef> refs = <WikiLinkRef>[];
    final List<_Range> codeRanges = _codeRanges(body);
    for (final Match match in _pattern.allMatches(body)) {
      if (_within(codeRanges, match.start)) {
        continue;
      }
      final String inner = match.group(1)!;
      final int pipe = inner.indexOf('|');
      final String target = (pipe < 0 ? inner : inner.substring(0, pipe))
          .trim();
      if (target.isEmpty) {
        continue;
      }
      final String label = pipe < 0 ? target : inner.substring(pipe + 1).trim();
      refs.add(
        WikiLinkRef(
          target: target,
          label: label.isEmpty ? target : label,
          start: match.start,
          end: match.end,
        ),
      );
    }
    return refs;
  }

  /// The spans of inline (`` `...` ``) and fenced (```` ``` ````) code in
  /// [body], so wiki-links inside code are ignored.
  static List<_Range> _codeRanges(String body) {
    final List<_Range> ranges = <_Range>[];
    for (final Match m in _fence.allMatches(body)) {
      ranges.add(_Range(m.start, m.end));
    }
    for (final Match m in _inlineCode.allMatches(body)) {
      ranges.add(_Range(m.start, m.end));
    }
    return ranges;
  }

  static bool _within(List<_Range> ranges, int offset) {
    for (final _Range range in ranges) {
      if (offset >= range.start && offset < range.end) {
        return true;
      }
    }
    return false;
  }

  // Non-greedy inner capture; `[[` and `]]` with no nested `]]`.
  static final RegExp _pattern = RegExp(r'\[\[([^\]]*?)\]\]');
  static final RegExp _inlineCode = RegExp(r'`[^`\n]*`');
  static final RegExp _fence = RegExp(r'```[\s\S]*?```', multiLine: true);
}

final class _Range {
  const _Range(this.start, this.end);
  final int start;
  final int end;
}
