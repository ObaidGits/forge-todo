import 'package:forge/app/routing/canonical_route.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// The MVP search entity types shown as filter chips and result groups, in a
/// stable display order (R-SEARCH-001, R-SEARCH-002).
///
/// The type discriminators are the shared canonical vocabulary emitted by the
/// per-feature search projectors ([CanonicalEntityType]); the search feature
/// never imports another feature's infrastructure to learn them (design.md
/// §16).
const List<String> mvpSearchTypes = <String>[
  CanonicalEntityType.task,
  CanonicalEntityType.note,
  CanonicalEntityType.goal,
  CanonicalEntityType.roadmapTopic,
  CanonicalEntityType.learningResourceSearch,
  CanonicalEntityType.habit,
];

/// The localized display label for a search entity [type].
String searchTypeLabel(AppLocalizations l10n, String type) => switch (type) {
  CanonicalEntityType.task => l10n.searchGroupTask,
  CanonicalEntityType.note => l10n.searchGroupNote,
  CanonicalEntityType.goal => l10n.searchGroupGoal,
  CanonicalEntityType.roadmapTopic => l10n.searchGroupRoadmapTopic,
  CanonicalEntityType.learningResourceSearch =>
    l10n.searchGroupLearningResource,
  CanonicalEntityType.habit => l10n.searchGroupHabit,
  _ => l10n.searchGroupOther,
};
