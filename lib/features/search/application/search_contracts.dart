/// Stable application-boundary contracts for the unified search feature.
///
/// Features that own searchable source rows depend only on this barrel to
/// implement a [SearchProjector] and emit correctly-keyed `search` dirty
/// markers, satisfying the cross-feature import fitness rule (design.md §16):
/// other features never reach into the search feature's infrastructure.
library;

export 'package:forge/features/search/application/search_projector.dart';
export 'package:forge/features/search/domain/search_dirty_key.dart';
export 'package:forge/features/search/domain/search_document.dart';
