import 'package:drift/drift.dart';

/// DDL and shared constants for the `search_fts` FTS5 external-content index
/// (design.md §14, R-SEARCH-001..003).
///
/// Drift has no virtual-table DSL, so the FTS5 index is created by explicit DDL
/// on top of the `search_documents` content table. It is an external-content
/// index (`content='search_documents'`): the index stores only the tokenized
/// structure while the display text is read back from `search_documents` by the
/// stable `doc_rowid`. Highlighting, snippets and BM25 ranking are provided by
/// FTS5 auxiliary functions.
abstract final class SearchFts {
  /// The FTS5 virtual table name.
  static const String table = 'search_fts';

  /// Content table backing the external-content index.
  static const String contentTable = 'search_documents';

  /// Column ordinals used by `highlight()` / `snippet()`.
  static const int titleColumn = 0;
  static const int bodyColumn = 1;

  /// Safe highlight markers. Control characters cannot appear in indexed source
  /// text (titles/bodies are user content, never control bytes) so they cannot
  /// be forged by a query and are stripped/escaped by the presentation layer.
  static const String highlightOpen = '\u0002';
  static const String highlightClose = '\u0003';

  /// Creates the FTS5 external-content index. Uses `unicode61` with diacritic
  /// folding so search is accent-insensitive while display spelling is
  /// preserved in `search_documents` (data-model §4 "Unicode normalized keys
  /// preserve display spelling").
  static Future<void> create(GeneratedDatabase db) async {
    await db.customStatement(
      "CREATE VIRTUAL TABLE IF NOT EXISTS $table USING fts5("
      'title, '
      'body, '
      "content='$contentTable', "
      "content_rowid='doc_rowid', "
      "tokenize='unicode61 remove_diacritics 2'"
      ')',
    );
  }
}
