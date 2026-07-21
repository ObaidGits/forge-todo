import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/command/search_projection_coordinator.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/features/search/application/search_projector.dart';
import 'package:forge/features/search/domain/search_dirty_key.dart';
import 'package:forge/features/search/domain/search_document.dart';
import 'package:forge/features/search/infrastructure/search_write_repository.dart';

/// The registry of typed search projectors and the in-transaction coordinator
/// that drives them (design.md §14, R-SEARCH-001).
///
/// Each release-present searchable type registers exactly one [SearchProjector].
/// The registry is extensible: later waves add note/goal/roadmap-topic/learning/
/// habit/workout projectors without touching the command bus or existing
/// projectors. Registering two projectors for the same entity type is a wiring
/// error and throws.
final class SearchProjectionRegistry implements SearchProjectionCoordinator {
  SearchProjectionRegistry(Iterable<SearchProjector> projectors)
    : _projectors = _index(projectors);

  final Map<String, SearchProjector> _projectors;

  /// The entity types with a registered projector, sorted for deterministic
  /// rebuild ordering.
  List<String> get entityTypes =>
      _projectors.keys.toList(growable: false)..sort();

  SearchProjector? projectorFor(String entityType) => _projectors[entityType];

  @override
  Future<void> maintain(
    TransactionSession session,
    String profileId,
    List<DirtyProjectionDraft> searchMarkers,
    int nowUtc,
  ) async {
    if (searchMarkers.isEmpty) {
      return;
    }
    final SearchWriteRepository writes = session.repositories
        .resolve<SearchWriteRepository>();
    // Collapse duplicate markers for the same entity within one write.
    final Set<String> handled = <String>{};
    for (final DirtyProjectionDraft marker in searchMarkers) {
      if (marker.projection != SearchDirtyKey.projection) {
        continue;
      }
      if (!handled.add(marker.projectionKey)) {
        continue;
      }
      final SearchDirtyRef? ref = SearchDirtyKey.decode(marker.projectionKey);
      if (ref == null) {
        continue;
      }
      await _project(
        session: session,
        writes: writes,
        profileId: profileId,
        entityType: ref.entityType,
        entityId: ref.entityId,
        nowUtc: nowUtc,
      );
    }
  }

  /// Regenerates the entire search index for [profileId] from source rows.
  /// Clears existing documents, then re-projects every enumerated entity for
  /// every registered projector (data-model §4 "migrations/rebuilds regenerate
  /// entirely from source rows").
  Future<int> rebuildFromSources(
    TransactionSession session,
    String profileId,
    int nowUtc,
  ) async {
    final SearchWriteRepository writes = session.repositories
        .resolve<SearchWriteRepository>();
    await writes.clearProfile(profileId);
    int regenerated = 0;
    for (final String entityType in entityTypes) {
      final SearchProjector projector = _projectors[entityType]!;
      final List<String> ids = await projector.enumerateEntityIds(
        session,
        profileId,
      );
      for (final String entityId in ids) {
        final SearchDocumentDraft? draft = await projector.buildDocument(
          session,
          profileId,
          entityId,
        );
        if (draft != null) {
          await writes.upsert(draft, profileId: profileId, nowUtc: nowUtc);
          regenerated += 1;
        }
      }
    }
    return regenerated;
  }

  /// Projects a single entity referenced by a `search` marker. Returns true
  /// when a projector handled it (used by the reconciler for accounting).
  Future<bool> projectEntity({
    required TransactionSession session,
    required String profileId,
    required String entityType,
    required String entityId,
    required int nowUtc,
  }) async {
    final SearchWriteRepository writes = session.repositories
        .resolve<SearchWriteRepository>();
    return _project(
      session: session,
      writes: writes,
      profileId: profileId,
      entityType: entityType,
      entityId: entityId,
      nowUtc: nowUtc,
    );
  }

  Future<bool> _project({
    required TransactionSession session,
    required SearchWriteRepository writes,
    required String profileId,
    required String entityType,
    required String entityId,
    required int nowUtc,
  }) async {
    final SearchProjector? projector = _projectors[entityType];
    if (projector == null) {
      return false;
    }
    final SearchDocumentDraft? draft = await projector.buildDocument(
      session,
      profileId,
      entityId,
    );
    if (draft == null) {
      await writes.tombstone(
        profileId: profileId,
        entityType: entityType,
        entityId: entityId,
        nowUtc: nowUtc,
      );
    } else {
      await writes.upsert(draft, profileId: profileId, nowUtc: nowUtc);
    }
    return true;
  }

  static Map<String, SearchProjector> _index(
    Iterable<SearchProjector> projectors,
  ) {
    final Map<String, SearchProjector> map = <String, SearchProjector>{};
    for (final SearchProjector projector in projectors) {
      if (map.containsKey(projector.entityType)) {
        throw ArgumentError.value(
          projector.entityType,
          'projectors',
          'Duplicate search projector registered for entity type.',
        );
      }
      map[projector.entityType] = projector;
    }
    return map;
  }
}
