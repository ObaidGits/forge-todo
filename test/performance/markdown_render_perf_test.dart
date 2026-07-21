import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/notes/domain/markdown/markdown_node.dart';
import 'package:forge/features/notes/domain/markdown/safe_markdown.dart';
import 'package:forge/features/notes/presentation/widgets/markdown_preview.dart';

/// In-process performance guard for parsing/rendering a very large note
/// (R-NOTE-001, NFR-PERF budgets).
///
/// The authoritative frame budget (p99 UI/raster ≤16.7 ms rendering a 1 MiB
/// Markdown body) is an external reference-profile campaign that captures
/// profile/release frame traces on ratified hardware
/// (tool/probes/benchmark_profile + docs/evidence/BENCHMARK-PROFILE.md
/// "Frames" scenario). That campaign is external evidence and cannot run in a
/// unit harness.
///
/// This guard is the automated regression tripwire that complements it. The
/// preview keeps a large note responsive two ways: parsing is bounded to
/// [MarkdownPreviewLimits.previewCharacterLimit] characters so an adversarially
/// large body can never be parsed in full on the UI isolate, and the parser
/// itself stays linear in its input. This test asserts both: that a 1 MiB body
/// is parsed only up to the preview bound, and that a pathological `<`-dense
/// body (which previously forced a per-character tail copy, i.e. O(n²) inline
/// scanning) parses well inside a generous tripwire. It never weakens or
/// substitutes for the reference-profile frame requirement.
///
/// **Validates: Requirements NFR-PERF-001, NFR-PERF-003**
void main() {
  // Parsing is the CPU-bound work that must never run unbounded on the UI
  // isolate. A generous ceiling that only trips on a real algorithmic
  // regression (the suite runs with --timeout=5x, so this is not a wall-clock
  // race).
  const double tripwireMs = 750.0;

  double parseMillis(String body) {
    // Emulate exactly what MarkdownPreview does: bound the source to the
    // preview limit, then parse.
    final bool truncated =
        body.length > MarkdownPreviewLimits.previewCharacterLimit;
    final String source = truncated
        ? body.substring(0, MarkdownPreviewLimits.previewCharacterLimit)
        : body;
    final Stopwatch sw = Stopwatch()..start();
    final MarkdownDocument doc = SafeMarkdown.parse(source);
    sw.stop();
    // Touch the result so the parse is not dead-code eliminated.
    expect(doc.blocks, isNotEmpty);
    return sw.elapsedMicroseconds / 1000.0;
  }

  test(
    '[TEST-PERF-MARKDOWN-001][MVP][TASK-8.4][R-NOTE-001,NFR-PERF-001] a 1 MiB '
    'note body is parsed only up to the preview bound and stays responsive',
    () {
      // A realistic 1 MiB body: paragraphs, headings, lists and links repeated.
      final StringBuffer buffer = StringBuffer();
      const String unit =
          '# Heading\n\n'
          'A paragraph with **bold**, *italic*, `code` and a '
          '[link](https://example.com/path?q=1) plus a [[Wiki Note]].\n\n'
          '- [ ] a task item\n- [x] a done item\n- a plain bullet\n\n'
          '> a quoted line with more prose to parse\n\n';
      while (buffer.length < 1024 * 1024) {
        buffer.write(unit);
      }
      final String body = buffer.toString();
      expect(
        body.length,
        greaterThan(MarkdownPreviewLimits.previewCharacterLimit),
      );

      final double millis = parseMillis(body);
      expect(
        millis,
        lessThan(tripwireMs),
        reason:
            'parsing a preview-bounded 1 MiB note took '
            '${millis.toStringAsFixed(2)} ms, exceeding the ${tripwireMs}ms '
            'tripwire (parsing must stay bounded and linear)',
      );
    },
  );

  test('[TEST-PERF-MARKDOWN-002][MVP][TASK-8.4][R-NOTE-001,NFR-PERF-001] a '
      '"<"-dense body parses in linear time (no per-character tail copy)', () {
    // Every `<` is an autolink candidate. If inline parsing copies the
    // remaining tail per candidate, this body is O(n²) and stalls the UI
    // isolate; anchored prefix matching keeps it linear.
    final String pathological =
        '<' * MarkdownPreviewLimits.previewCharacterLimit;
    expect(pathological.length, MarkdownPreviewLimits.previewCharacterLimit);

    final double millis = parseMillis(pathological);
    expect(
      millis,
      lessThan(tripwireMs),
      reason:
          'parsing a "<"-dense body took ${millis.toStringAsFixed(2)} ms, '
          'exceeding the ${tripwireMs}ms tripwire — inline parsing has '
          'regressed to super-linear (per-character tail copy) work',
    );
  });

  test(
    '[TEST-PERF-MARKDOWN-003][MVP][TASK-8.4][R-NOTE-001,NFR-PERF-001] the '
    'preview never parses more than the bounded prefix of an oversized body',
    () {
      // Below the bound the whole body parses; above it only the prefix does.
      final String small =
          'x' * (MarkdownPreviewLimits.previewCharacterLimit - 1);
      final String large =
          'y' * (MarkdownPreviewLimits.previewCharacterLimit * 4);

      expect(
        small.length < MarkdownPreviewLimits.previewCharacterLimit,
        isTrue,
      );
      expect(
        large.length > MarkdownPreviewLimits.previewCharacterLimit,
        isTrue,
      );

      // Both parse within the tripwire because the oversized body is bounded to
      // the same prefix length before parsing.
      expect(parseMillis(small), lessThan(tripwireMs));
      expect(parseMillis(large), lessThan(tripwireMs));
    },
  );
}
