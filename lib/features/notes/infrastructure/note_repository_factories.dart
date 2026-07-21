import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/notes/domain/note_entity_link.dart';
import 'package:forge/features/notes/infrastructure/attachment_repository.dart';
import 'package:forge/features/notes/infrastructure/note_draft_repository.dart';
import 'package:forge/features/notes/infrastructure/note_entity_link_repository.dart';
import 'package:forge/features/notes/infrastructure/note_write_repository.dart';

/// The centralized owner registry for note→entity links: recognized target
/// type → the physical table carrying `(profile_id, id)` (data-model §1).
///
/// A note may link only to types present here, and every target is
/// existence-checked under the note's own profile so cross-profile references
/// are rejected in the writing transaction (R-GEN-002). The map grows as
/// owning features land: `task` is present from Wave 3; goals, roadmaps,
/// Learning Resources (`course`), and habits register their tables in their
/// respective waves, at which point notes can link to them without any change
/// to the notes feature.
const Map<String, String> noteEntityOwnerTables = <String, String>{
  NoteEntityTargetType.task: 'tasks',
  // Wave 5: goals, roadmaps, and Learning Resources (internal `courses`) own
  // `(profile_id, id)` and can be linked from a canonical note (R-NOTE-002).
  NoteEntityTargetType.goal: 'goals',
  NoteEntityTargetType.roadmap: 'roadmaps',
  NoteEntityTargetType.learningResource: 'courses',
  // Wave 9 (task 10.5): a logged workout session owns `(profile_id, id)` in
  // `workout_sessions` and can be linked from a canonical note so workouts
  // participate in the unified entity-link graph (R-FIT-001, R-NOTE-002).
  NoteEntityTargetType.workout: 'workout_sessions',
};

/// Transaction-scoped repository factories contributed by the notes feature.
///
/// The outer composition root merges these into the [DriftUnitOfWork] so a
/// command body can resolve a [NoteWriteRepository] (notes/links/tags), a
/// [NoteDraftWriteRepository] (encrypted draft journal), or a
/// [NoteEntityLinkRepository] (note→entity links) bound to the active
/// transaction (design.md §5/§6). Registering factories here keeps the notes
/// DAO owned by the notes feature.
final Map<Type, RepositoryFactory>
noteRepositoryFactories = <Type, RepositoryFactory>{
  NoteWriteRepository: (ForgeSchemaDatabase db, TransactionScope scope) =>
      NoteWriteRepository(db, scope),
  NoteDraftWriteRepository: (ForgeSchemaDatabase db, TransactionScope scope) =>
      NoteDraftWriteRepository(db, scope),
  NoteEntityLinkRepository: (ForgeSchemaDatabase db, TransactionScope scope) =>
      NoteEntityLinkRepository(db, scope, noteEntityOwnerTables),
  // Managed attachments (task 10.3, R-NOTE-006). Publication and soft-deletion
  // run inside the same transaction as the durable file-journal advance.
  AttachmentWriteRepository: (ForgeSchemaDatabase db, TransactionScope scope) =>
      AttachmentWriteRepository(db, scope),
};

/// The trashable entity descriptor for notes (R-GEN-003, R-NOTE-002). The
/// composition root adds this to the shared `TrashRegistry` so note trash /
/// restore / purge reuse the deletion kernel. Notes are sync-eligible, so
/// ordinary deletion produces a replicated tombstone.
const String noteTrashableEntityType = 'note';
