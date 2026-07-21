/// Exact-base three-way note merge, or a conflict copy (R-NOTE-007,
/// data-model.md §6 rule 5).
///
/// A note's Markdown body is the single canonical source of truth. When two
/// devices edit the same body concurrently, the client attempts a line-level
/// three-way merge **only** when the exact base body is retained and the two
/// edits do not overlap. A base *hash* alone never authorizes a merge — the
/// caller must supply the actual base text — so this API takes the base body,
/// not a fingerprint. When a clean merge is impossible, neither body is lost:
/// the current body persists and a conflict-copy note is created, backed by a
/// durable conflict artifact.
///
/// The merge is a pure, deterministic line-level diff3: it is defined entirely
/// by the three input strings and performs no IO.
library;

/// Whether a merge produced a single reconciled body or requires a conflict
/// copy because the edits overlapped (or no exact base was available).
enum NoteMergeKind { merged, conflictCopy }

/// The result of a three-way note-body merge.
final class NoteMergeResult {
  const NoteMergeResult._({
    required this.kind,
    required this.mergedBody,
    required this.base,
    required this.local,
    required this.remote,
  });

  factory NoteMergeResult.merged(String body) => NoteMergeResult._(
    kind: NoteMergeKind.merged,
    mergedBody: body,
    base: null,
    local: null,
    remote: null,
  );

  factory NoteMergeResult.conflictCopy({
    required String? base,
    required String local,
    required String remote,
  }) => NoteMergeResult._(
    kind: NoteMergeKind.conflictCopy,
    mergedBody: null,
    base: base,
    local: local,
    remote: remote,
  );

  final NoteMergeKind kind;

  /// The reconciled body when [kind] is [NoteMergeKind.merged].
  final String? mergedBody;

  /// The three inputs, retained when a conflict copy is required so both bodies
  /// survive in a durable artifact.
  final String? base;
  final String? local;
  final String? remote;

  bool get isMerged => kind == NoteMergeKind.merged;
  bool get isConflictCopy => kind == NoteMergeKind.conflictCopy;
}

/// Merges [local] and [remote] against their exact [base].
///
/// Returns a [NoteMergeResult.merged] when:
///  * the two sides are identical (no divergence);
///  * only one side changed the base;
///  * both sides changed the base but their changed line regions are disjoint
///    (a clean three-way merge).
///
/// Returns a [NoteMergeResult.conflictCopy] when:
///  * [base] is null (the exact base body was not retained — a hash is never
///    enough); or
///  * both sides changed the same region differently (overlapping edits).
NoteMergeResult mergeNoteBody({
  required String? base,
  required String local,
  required String remote,
}) {
  if (base == null) {
    // No exact base retained: a hash alone never authorizes a merge.
    return NoteMergeResult.conflictCopy(
      base: base,
      local: local,
      remote: remote,
    );
  }
  if (local == remote) {
    return NoteMergeResult.merged(local);
  }
  if (local == base) {
    return NoteMergeResult.merged(remote);
  }
  if (remote == base) {
    return NoteMergeResult.merged(local);
  }

  final List<String> baseLines = _splitLines(base);
  final List<String> localLines = _splitLines(local);
  final List<String> remoteLines = _splitLines(remote);

  final String? merged = _diff3(
    base: baseLines,
    local: localLines,
    remote: remoteLines,
  );
  if (merged == null) {
    return NoteMergeResult.conflictCopy(
      base: base,
      local: local,
      remote: remote,
    );
  }
  return NoteMergeResult.merged(merged);
}

/// Splits a body into lines while preserving the exact terminator structure so
/// a round-trip (`_join(_splitLines(x)) == x`) is lossless.
List<String> _splitLines(String body) {
  if (body.isEmpty) {
    return <String>[];
  }
  final List<String> lines = <String>[];
  final StringBuffer current = StringBuffer();
  for (int i = 0; i < body.length; i += 1) {
    final String ch = body[i];
    current.write(ch);
    if (ch == '\n') {
      lines.add(current.toString());
      current.clear();
    }
  }
  if (current.isNotEmpty) {
    lines.add(current.toString());
  }
  return lines;
}

String _join(List<String> lines) => lines.join();

/// A line-level diff3 merge. Returns the merged body, or null when the two
/// sides changed the same region incompatibly (an overlapping edit).
String? _diff3({
  required List<String> base,
  required List<String> local,
  required List<String> remote,
}) {
  // Stable anchor points: base lines that survive unchanged in BOTH sides,
  // aligned by the two-way longest common subsequences. Intersecting the two
  // alignments by base index keeps the anchors increasing in all three
  // coordinates, which is exactly the property diff3 chunking needs.
  final List<List<int>> localPairs = _lcsPairs(base, local);
  final List<List<int>> remotePairs = _lcsPairs(base, remote);

  final Map<int, int> localByBase = <int, int>{
    for (final List<int> pair in localPairs) pair[0]: pair[1],
  };
  final Map<int, int> remoteByBase = <int, int>{
    for (final List<int> pair in remotePairs) pair[0]: pair[1],
  };

  final List<List<int>> anchors = <List<int>>[];
  for (final List<int> pair in localPairs) {
    final int baseIndex = pair[0];
    final int? remoteIndex = remoteByBase[baseIndex];
    if (remoteIndex != null) {
      anchors.add(<int>[baseIndex, pair[1], remoteIndex]);
    }
  }
  // Ensure the shared-base intersection is used consistently; localByBase is
  // referenced to keep both alignments symmetric for readers.
  assert(
    anchors.every((List<int> a) => localByBase[a[0]] == a[1]),
    'anchor local index must match the base-local alignment',
  );

  final StringBuffer out = StringBuffer();

  int prevBase = -1;
  int prevLocal = -1;
  int prevRemote = -1;

  // Append a trailing sentinel anchor past the end of all three sequences.
  final List<List<int>> walk = <List<int>>[
    ...anchors,
    <int>[base.length, local.length, remote.length],
  ];

  for (final List<int> anchor in walk) {
    final int baseIndex = anchor[0];
    final int localIndex = anchor[1];
    final int remoteIndex = anchor[2];

    final List<String> baseSlice = base.sublist(prevBase + 1, baseIndex);
    final List<String> localSlice = local.sublist(prevLocal + 1, localIndex);
    final List<String> remoteSlice = remote.sublist(
      prevRemote + 1,
      remoteIndex,
    );

    final String? region = _mergeRegion(baseSlice, localSlice, remoteSlice);
    if (region == null) {
      return null;
    }
    out.write(region);

    if (baseIndex < base.length) {
      // Emit the anchor line itself (identical across all three).
      out.write(base[baseIndex]);
    }

    prevBase = baseIndex;
    prevLocal = localIndex;
    prevRemote = remoteIndex;
  }

  return out.toString();
}

/// Merges one change region between two anchors. Returns the merged text, or
/// null when both sides changed the region differently (a real conflict).
String? _mergeRegion(
  List<String> base,
  List<String> local,
  List<String> remote,
) {
  final bool localChanged = !_linesEqual(base, local);
  final bool remoteChanged = !_linesEqual(base, remote);

  if (!localChanged && !remoteChanged) {
    return _join(base);
  }
  if (localChanged && !remoteChanged) {
    return _join(local);
  }
  if (!localChanged && remoteChanged) {
    return _join(remote);
  }
  // Both changed: only clean when they made the identical change.
  if (_linesEqual(local, remote)) {
    return _join(local);
  }
  return null;
}

bool _linesEqual(List<String> a, List<String> b) {
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i += 1) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// Longest-common-subsequence match pairs `[xIndex, yIndex]`, increasing in
/// both coordinates. Classic O(n*m) DP; note bodies are small.
List<List<int>> _lcsPairs(List<String> x, List<String> y) {
  final int n = x.length;
  final int m = y.length;
  final List<List<int>> dp = List<List<int>>.generate(
    n + 1,
    (_) => List<int>.filled(m + 1, 0),
    growable: false,
  );
  for (int i = n - 1; i >= 0; i -= 1) {
    for (int j = m - 1; j >= 0; j -= 1) {
      if (x[i] == y[j]) {
        dp[i][j] = dp[i + 1][j + 1] + 1;
      } else {
        dp[i][j] = dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1];
      }
    }
  }
  final List<List<int>> pairs = <List<int>>[];
  int i = 0;
  int j = 0;
  while (i < n && j < m) {
    if (x[i] == y[j]) {
      pairs.add(<int>[i, j]);
      i += 1;
      j += 1;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      i += 1;
    } else {
      j += 1;
    }
  }
  return pairs;
}
