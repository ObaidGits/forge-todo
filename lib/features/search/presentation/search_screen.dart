import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/routing/canonical_route.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/search/domain/saved_search_filter.dart';
import 'package:forge/features/search/domain/search_document.dart';
import 'package:forge/features/search/presentation/search_entity_types.dart';
import 'package:forge/features/search/presentation/search_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

/// Global search across every release-present entity type (R-SEARCH-001).
///
/// Results are grouped by type with safe highlighting and open each record's
/// local canonical projection (R-SEARCH-002). The index is fully local, so
/// results are available offline (R-SEARCH-003). Type filters and saved
/// searches let a scope be recalled. The surface is keyboard operable with
/// accessible names throughout (NFR-A11Y-001).
final class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: ref.read(searchQueryProvider));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;

    // Keep the field text in sync when a saved filter is applied elsewhere.
    ref.listen<String>(searchQueryProvider, (_, String next) {
      if (_controller.text != next) {
        _controller.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: next.length),
        );
      }
    });

    if (!ref.watch(searchConfiguredProvider)) {
      return _CenteredMessage(message: l10n.searchUnavailable);
    }

    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ForgeSpacing.md,
              ForgeSpacing.md,
              ForgeSpacing.md,
              ForgeSpacing.xs,
            ),
            child: _buildSearchField(context, l10n),
          ),
          _buildTypeFilters(context, l10n),
          _buildSavedFilters(context, l10n),
          const Divider(height: 1),
          Expanded(child: _buildResults(context, l10n)),
        ],
      ),
    );
  }

  Widget _buildSearchField(BuildContext context, AppLocalizations l10n) {
    final String query = ref.watch(searchQueryProvider);
    return FocusTraversalOrder(
      order: const NumericFocusOrder(1),
      child: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          labelText: l10n.searchFieldLabel,
          hintText: l10n.searchFieldHint,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: query.isEmpty
              ? null
              : IconButton(
                  tooltip: l10n.searchClear,
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    ref.read(searchQueryProvider.notifier).clear();
                  },
                ),
          border: const OutlineInputBorder(),
        ),
        onChanged: (String value) =>
            ref.read(searchQueryProvider.notifier).set(value),
      ),
    );
  }

  Widget _buildTypeFilters(BuildContext context, AppLocalizations l10n) {
    final Set<String> selected = ref.watch(searchTypesProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: ForgeSpacing.md),
      child: Semantics(
        label: l10n.searchFilters,
        container: true,
        child: Wrap(
          spacing: ForgeSpacing.xs,
          children: <Widget>[
            for (final String type in mvpSearchTypes)
              FilterChip(
                label: Text(searchTypeLabel(l10n, type)),
                selected: selected.contains(type),
                onSelected: (_) =>
                    ref.read(searchTypesProvider.notifier).toggle(type),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSavedFilters(BuildContext context, AppLocalizations l10n) {
    final AsyncValue<List<SavedSearchFilter>> saved = ref.watch(
      savedFiltersProvider,
    );
    final List<SavedSearchFilter> filters =
        saved.asData?.value ?? const <SavedSearchFilter>[];
    final String query = ref.watch(searchQueryProvider).trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ForgeSpacing.md,
        ForgeSpacing.xs,
        ForgeSpacing.md,
        ForgeSpacing.xs,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: filters.isEmpty
                ? const SizedBox.shrink()
                : Semantics(
                    label: l10n.searchSavedFilters,
                    container: true,
                    child: Wrap(
                      spacing: ForgeSpacing.xs,
                      children: <Widget>[
                        for (final SavedSearchFilter filter in filters)
                          InputChip(
                            label: Text(filter.name),
                            tooltip: l10n.searchSavedFilterApply(filter.name),
                            onPressed: () => ref
                                .read(savedFiltersProvider.notifier)
                                .apply(filter),
                            onDeleted: () => ref
                                .read(savedFiltersProvider.notifier)
                                .delete(filter.id),
                            deleteButtonTooltipMessage: l10n
                                .searchSavedFilterDelete(filter.name),
                          ),
                      ],
                    ),
                  ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: ForgeSizes.minimumInteractiveDimension,
              minHeight: ForgeSizes.minimumInteractiveDimension,
            ),
            child: IconButton(
              tooltip: l10n.searchSaveFilter,
              icon: const Icon(Icons.bookmark_add_outlined),
              onPressed: query.isEmpty
                  ? null
                  : () => _openSaveDialog(context, l10n),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context, AppLocalizations l10n) {
    final String query = ref.watch(searchQueryProvider).trim();
    if (query.isEmpty) {
      return _CenteredMessage(message: l10n.searchEmptyPrompt);
    }
    final AsyncValue<SearchResults> results = ref.watch(searchResultsProvider);
    return results.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, _) =>
          _CenteredMessage(message: l10n.errorUnexpected),
      data: (SearchResults data) {
        if (data.isEmpty) {
          return _CenteredMessage(message: l10n.searchNoResults(query));
        }
        return _ResultsList(results: data);
      },
    );
  }

  Future<void> _openSaveDialog(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final String query = ref.read(searchQueryProvider).trim();
    final Set<String> types = ref.read(searchTypesProvider);
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => const _SaveSearchDialog(),
    );
    if (name == null || name.isEmpty || !context.mounted) {
      return;
    }
    final bool ok = await ref
        .read(savedFiltersProvider.notifier)
        .saveCurrent(name: name, query: query, types: types);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(ok ? l10n.searchFilterSaved : l10n.searchFilterExists),
        ),
      );
  }
}

/// A name-entry dialog that owns its controller so it is disposed only after
/// the dialog's exit transition completes.
final class _SaveSearchDialog extends StatefulWidget {
  const _SaveSearchDialog();

  @override
  State<_SaveSearchDialog> createState() => _SaveSearchDialogState();
}

class _SaveSearchDialogState extends State<_SaveSearchDialog> {
  final TextEditingController _controller = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(_controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.searchSaveFilterTitle),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          maxLength: 60,
          decoration: InputDecoration(
            labelText: l10n.searchSaveFilterNameLabel,
            hintText: l10n.searchSaveFilterNameHint,
          ),
          validator: (String? value) => (value == null || value.trim().isEmpty)
              ? l10n.areaNameRequired
              : null,
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.dialogCancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.searchSaveFilterConfirm),
        ),
      ],
    );
  }
}

final class _ResultsList extends StatelessWidget {
  const _ResultsList({required this.results});

  final SearchResults results;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Semantics(
      label: l10n.searchResultsLabel,
      container: true,
      child: ListView(
        restorationId: 'content-search-results',
        padding: const EdgeInsets.all(ForgeSpacing.xs),
        children: <Widget>[
          for (final SearchResultGroup group in results.groups) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ForgeSpacing.sm,
                ForgeSpacing.sm,
                ForgeSpacing.sm,
                ForgeSpacing.xxs,
              ),
              child: Semantics(
                header: true,
                child: Text(
                  '${searchTypeLabel(l10n, group.entityType)} '
                  '· ${l10n.searchResultCount(group.hits.length)}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ),
            for (final SearchHit hit in group.hits)
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: ForgeSizes.readableContentMaxWidth,
                ),
                child: _HitTile(hit: hit),
              ),
          ],
        ],
      ),
    );
  }
}

final class _HitTile extends StatelessWidget {
  const _HitTile({required this.hit});

  final SearchHit hit;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final String? route = CanonicalRoute.forEntity(
      hit.entityType,
      hit.entityId,
    );
    final bool openable = route != null;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: ForgeSizes.minimumInteractiveDimension,
      ),
      child: Semantics(
        button: openable,
        label: openable ? l10n.searchOpenResult(hit.title) : hit.title,
        child: ListTile(
          title: Text.rich(
            _highlightedSpans(
              hit.titleHighlighted.isEmpty ? hit.title : hit.titleHighlighted,
              theme.textTheme.bodyLarge,
              theme,
            ),
          ),
          subtitle: hit.bodySnippet.isEmpty
              ? null
              : Text.rich(
                  _highlightedSpans(
                    hit.bodySnippet,
                    theme.textTheme.bodySmall,
                    theme,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
          onTap: openable ? () => context.go(route) : null,
        ),
      ),
    );
  }
}

/// Builds text spans from FTS-highlighted text, bolding the ranges the index
/// marked with the safe control-character sentinels. The markers are control
/// bytes that cannot appear in user content, so highlighting can never be
/// forged by query text (R-SEARCH-002 "highlight safely").
TextSpan _highlightedSpans(String marked, TextStyle? base, ThemeData theme) {
  final TextStyle highlight = (base ?? const TextStyle()).copyWith(
    fontWeight: FontWeight.bold,
    color: theme.colorScheme.primary,
  );
  final List<TextSpan> spans = <TextSpan>[];
  final StringBuffer buffer = StringBuffer();
  bool emphasized = false;
  void flush() {
    if (buffer.isEmpty) {
      return;
    }
    spans.add(
      TextSpan(text: buffer.toString(), style: emphasized ? highlight : base),
    );
    buffer.clear();
  }

  for (final int unit in marked.runes) {
    if (unit == 0x0002) {
      flush();
      emphasized = true;
    } else if (unit == 0x0003) {
      flush();
      emphasized = false;
    } else {
      buffer.writeCharCode(unit);
    }
  }
  flush();
  return TextSpan(children: spans);
}

final class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ForgeSpacing.xl),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    );
  }
}
