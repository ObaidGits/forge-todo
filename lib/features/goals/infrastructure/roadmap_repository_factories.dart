import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/goals/infrastructure/roadmap_write_repository.dart';

/// Transaction-scoped repository factories contributed by the roadmap side of
/// the goals feature.
///
/// The outer composition root merges these into the [DriftUnitOfWork] so a
/// command body can resolve a [RoadmapWriteRepository] (roadmaps, sections,
/// topics, checklist items) bound to the active transaction (design.md §5/§6).
/// Registering factories here keeps the roadmap DAO owned by the goals feature.
final Map<Type, RepositoryFactory> roadmapRepositoryFactories =
    <Type, RepositoryFactory>{
      RoadmapWriteRepository:
          (ForgeSchemaDatabase db, TransactionScope scope) =>
              RoadmapWriteRepository(db, scope),
    };

/// The trashable entity types for the roadmap tree (R-GEN-003, R-GOAL-007).
/// The composition root adds these to the shared `TrashRegistry` so roadmap
/// trash / restore / purge reuse the deletion kernel. They are sync-eligible,
/// so ordinary deletion produces a replicated tombstone.
const String roadmapTrashableEntityType = 'roadmap';
const String roadmapSectionTrashableEntityType = 'roadmap_section';
const String roadmapTopicTrashableEntityType = 'roadmap_topic';
const String checklistItemTrashableEntityType = 'checklist_item';
