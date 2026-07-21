import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:forge/app/composition/first_run_provisioning.dart';
import 'package:forge/app/composition/forge_search_projectors.dart';
import 'package:forge/app/infrastructure/database/active_generation_pointer.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/database_runtime.dart';
import 'package:forge/app/infrastructure/database/deletion/deletion_maintenance.dart';
import 'package:forge/app/infrastructure/database/deletion/deletion_service.dart';
import 'package:forge/app/infrastructure/database/deletion/purge_preview.dart';
import 'package:forge/app/infrastructure/database/deletion/trashable_entity.dart';
import 'package:forge/app/infrastructure/database/encrypted/sqlite3mc_encrypted_store.dart';
import 'package:forge/app/infrastructure/database/migration/encrypted_migration_connection.dart';
import 'package:forge/app/infrastructure/database/migration/generation_migrator.dart'
    show MigrationLayout;
import 'package:forge/app/infrastructure/database/recovery_mode.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/sync/acknowledgement_service.dart';
import 'package:forge/app/infrastructure/database/sync/pull_apply_coordinator.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/app/infrastructure/id/uuid_v7_generator.dart';
import 'package:forge/app/infrastructure/security/flutter_secure_key_store.dart';
import 'package:forge/app/infrastructure/security/local_file_key_vault.dart';
import 'package:forge/app/infrastructure/security/secure_storage_key_vault.dart';
import 'package:forge/app/infrastructure/system_clock.dart';
import 'package:forge/app/infrastructure/system_monotonic_clock.dart';
import 'package:forge/app/infrastructure/time/timezone_resolver.dart';
import 'package:forge/config/app_config.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/time_zone.dart';
import 'package:forge/core/security/key_vault.dart';
import 'package:forge/core/security/redacting_log.dart';
import 'package:forge/core/security/secure_key_store.dart';
import 'package:forge/features/areas/application/life_area_command_service.dart';
import 'package:forge/features/areas/application/life_area_query_service.dart';
import 'package:forge/features/areas/infrastructure/area_repository_factories.dart';
import 'package:forge/features/areas/infrastructure/life_area_command_service_drift.dart';
import 'package:forge/features/areas/infrastructure/life_area_read_repository.dart';
import 'package:forge/features/backup/application/recovery_center.dart';
import 'package:forge/features/backup/infrastructure/fbc1_container.dart';
import 'package:forge/features/backup/infrastructure/point_in_time_export.dart';
import 'package:forge/features/backup/infrastructure/pointycastle_backup_crypto.dart';
import 'package:forge/features/backup/infrastructure/recovery_center.dart'
    as backup_infra;
import 'package:forge/features/backup/infrastructure/staged_restore.dart';
import 'package:forge/features/fitness/application/fitness_command_service.dart';
import 'package:forge/features/fitness/application/fitness_query_service.dart';
import 'package:forge/features/fitness/infrastructure/fitness_command_service_drift.dart';
import 'package:forge/features/fitness/infrastructure/fitness_query_service_drift.dart';
import 'package:forge/features/fitness/infrastructure/fitness_read_repository.dart';
import 'package:forge/features/fitness/infrastructure/fitness_remote_appliers.dart';
import 'package:forge/features/fitness/infrastructure/fitness_repository_factories.dart';
import 'package:forge/features/fitness/infrastructure/settings_water_tracking_store.dart';
import 'package:forge/features/focus/application/focus_command_service.dart';
import 'package:forge/features/focus/application/focus_session_read_contract.dart';
import 'package:forge/features/focus/application/focus_today_contract.dart';
import 'package:forge/features/focus/infrastructure/focus_command_service_drift.dart';
import 'package:forge/features/focus/infrastructure/focus_read_repository.dart';
import 'package:forge/features/focus/infrastructure/focus_repository_factories.dart';
import 'package:forge/features/goals/application/goal_command_service.dart';
import 'package:forge/features/goals/application/roadmap_command_service.dart';
import 'package:forge/features/goals/domain/goal_repository.dart';
import 'package:forge/features/goals/domain/roadmap_repository.dart';
import 'package:forge/features/goals/infrastructure/goal_command_service_drift.dart';
import 'package:forge/features/goals/infrastructure/goal_read_repository.dart';
import 'package:forge/features/goals/infrastructure/goal_repository_factories.dart';
import 'package:forge/features/goals/infrastructure/roadmap_command_service_drift.dart';
import 'package:forge/features/goals/infrastructure/roadmap_read_repository.dart';
import 'package:forge/features/goals/infrastructure/roadmap_repository_factories.dart';
import 'package:forge/features/habits/application/habit_command_service.dart';
import 'package:forge/features/habits/application/habit_query_service.dart';
import 'package:forge/features/habits/infrastructure/habit_command_service_drift.dart';
import 'package:forge/features/habits/infrastructure/habit_query_service_drift.dart';
import 'package:forge/features/habits/infrastructure/habit_repository_factories.dart';
import 'package:forge/features/home/application/home_layout_store.dart';
import 'package:forge/features/home/infrastructure/settings_home_layout_store.dart';
import 'package:forge/features/insights/application/combined_time_metrics_service.dart';
import 'package:forge/features/insights/application/period_insights_service.dart';
import 'package:forge/features/insights/infrastructure/drift_aggregate_cache_store.dart';
import 'package:forge/features/learning/application/learning_command_service.dart';
import 'package:forge/features/learning/application/learning_resume_contract.dart';
import 'package:forge/features/learning/domain/learning_repository.dart';
import 'package:forge/features/learning/infrastructure/learning_command_service_drift.dart';
import 'package:forge/features/learning/infrastructure/learning_read_repository.dart';
import 'package:forge/features/learning/infrastructure/learning_repository_factories.dart';
import 'package:forge/features/notes/application/note_command_service.dart';
import 'package:forge/features/notes/application/note_draft_journal.dart';
import 'package:forge/features/notes/domain/note_repository.dart';
import 'package:forge/features/notes/infrastructure/aead_note_draft_cipher.dart';
import 'package:forge/features/notes/infrastructure/note_command_service_drift.dart';
import 'package:forge/features/notes/infrastructure/note_draft_journal_drift.dart';
import 'package:forge/features/notes/infrastructure/note_link_deletion_maintenance.dart';
import 'package:forge/features/notes/infrastructure/note_read_repository.dart';
import 'package:forge/features/notes/infrastructure/note_repository_factories.dart';
import 'package:forge/features/notifications/application/reminder_service.dart';
import 'package:forge/features/notifications/infrastructure/horizon_reminder_scheduler.dart';
import 'package:forge/features/notifications/infrastructure/local_notifications_transport.dart';
import 'package:forge/features/notifications/infrastructure/reminder_repositories.dart';
import 'package:forge/features/notifications/infrastructure/reminder_repository_factories.dart';
import 'package:forge/features/planner/application/planner_command_service.dart';
import 'package:forge/features/planner/domain/planner_repository.dart';
import 'package:forge/features/planner/infrastructure/planner_command_service_drift.dart';
import 'package:forge/features/planner/infrastructure/planner_read_repository.dart';
import 'package:forge/features/planner/infrastructure/planner_repository_factories.dart';
import 'package:forge/features/planner/infrastructure/planner_summary_repository.dart';
import 'package:forge/features/search/application/saved_filters_store.dart';
import 'package:forge/features/search/application/search_service.dart';
import 'package:forge/features/search/infrastructure/search_read_repository.dart';
import 'package:forge/features/search/infrastructure/search_repository_factories.dart';
import 'package:forge/features/search/infrastructure/settings_saved_filters_store.dart';
import 'package:forge/features/sync/application/forge_replication_manifest.dart';
import 'package:forge/features/sync/application/remote_applier.dart';
import 'package:forge/features/sync/application/sync_serialization.dart';
import 'package:forge/features/sync/domain/sync_backend_config.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';
import 'package:forge/features/sync/infrastructure/gotrue_auth_client.dart';
import 'package:forge/features/sync/infrastructure/secure_token_store.dart';
import 'package:forge/features/sync/infrastructure/supabase_remote_profile_gateway.dart';
import 'package:forge/features/sync/infrastructure/supabase_sync_engine.dart';
import 'package:forge/features/sync/infrastructure/supabase_sync_environment.dart';
import 'package:forge/features/sync/infrastructure/supabase_sync_service.dart';
import 'package:forge/features/sync/infrastructure/supabase_sync_transport.dart';
import 'package:forge/features/tasks/application/recurrence_command_service.dart';
import 'package:forge/features/tasks/application/task_command_service.dart';
import 'package:forge/features/tasks/application/task_query_service.dart';
import 'package:forge/features/tasks/infrastructure/drift_task_query_service.dart';
import 'package:forge/features/tasks/infrastructure/recurrence_command_service_drift.dart';
import 'package:forge/features/tasks/infrastructure/task_command_service_drift.dart';
import 'package:forge/features/tasks/infrastructure/task_read_repository.dart';
import 'package:forge/features/tasks/infrastructure/task_repository_factories.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart' as pc;

/// The core-schema version this build supports. It MUST equal
/// [ForgeSchemaDatabase.schemaVersion]; it is duplicated here only so the
/// bootstrap can describe the initial generation before any database is opened.
const int kForgeSchemaVersion = 14;

/// The outcome of [bootstrapForge]: either a fully wired, ready runtime, or a
/// non-destructive Recovery-Mode entry the UI must surface (R-SEC-001).
sealed class BootstrapResult {
  const BootstrapResult();
}

/// A ready runtime with all feature services constructed and the active profile
/// resolved/seeded.
final class BootstrapReady extends BootstrapResult {
  const BootstrapReady({
    required this.runtime,
    required this.runtimeFactory,
    required this.clock,
    required this.profileId,
    required this.quickCaptureAreaId,
    required this.layoutStore,
    required this.taskQuery,
    required this.taskCommands,
    required this.learningResume,
    required this.learningRepository,
    required this.learningCommands,
    required this.habitQuery,
    required this.habitCommands,
    required this.focusContract,
    required this.focusSessionRead,
    required this.focusCommands,
    // Tasks feature (list, detail, recurrence, trash + purge).
    required this.taskRecurrence,
    required this.taskDeletion,
    required this.taskPurgePreview,
    // Goals + roadmap feature.
    required this.goalRepository,
    required this.roadmapRepository,
    required this.goalCommands,
    required this.roadmapCommands,
    // Planner feature (daily planning record read + durable commands).
    required this.plannerRepository,
    required this.plannerCommands,
    // Notes feature (read, commands, trash). The encrypted draft journal is
    // wired only when a production draft cipher is available; see below.
    required this.noteRepository,
    required this.noteCommands,
    required this.noteDeletion,
    this.noteDraftJournal,
    // Search feature.
    required this.searchService,
    required this.savedFilters,
    // Life Areas feature.
    required this.areaQuery,
    required this.areaCommands,
    // Fitness feature (workout templates, sessions, body-weight measurements).
    required this.fitnessQuery,
    required this.fitnessCommands,
    // Insights feature (weekly/monthly comparisons).
    required this.insightsService,
    // Notifications feature (rolling-horizon OS reminder reconciliation).
    required this.reminderService,
    // Backup / recovery feature (recovery center over staged restore).
    this.recoveryCenter,
    this.backupExporter,
    // Optional cloud sync (R-SYNC-001/005/007). Null unless a backend is
    // configured via dart-define; the default local-first build is unchanged.
    this.syncService,
  });

  final DatabaseRuntime runtime;
  final DatabaseRuntimeFactory runtimeFactory;
  final Clock clock;
  final ProfileId profileId;
  final LifeAreaId quickCaptureAreaId;
  final HomeLayoutStore layoutStore;
  final TaskQueryService taskQuery;
  final TaskCommandService taskCommands;
  final LearningResumeContract learningResume;

  /// The learning read contract (domain repository) backing the Learn tab
  /// (R-LEARN-001..004).
  final LearningRepository learningRepository;

  /// The durable learning command contract backing the Learn tab
  /// (R-LEARN-001..002, R-LEARN-004).
  final LearningCommandService learningCommands;

  final HabitQueryService habitQuery;
  final HabitCommandService habitCommands;
  final FocusTodayContract focusContract;

  /// The focus per-session read contract backing the `/focus/<id>` detail
  /// surface (R-FOCUS-003).
  final FocusSessionReadContract focusSessionRead;

  final FocusCommandService focusCommands;

  // Tasks feature.
  final RecurrenceCommandService taskRecurrence;
  final DeletionService taskDeletion;
  final PurgePreviewService taskPurgePreview;

  // Goals + roadmap feature.
  final GoalRepository goalRepository;
  final RoadmapRepository roadmapRepository;
  final GoalCommandService goalCommands;
  final RoadmapCommandService roadmapCommands;

  // Planner feature.
  /// The planner read contract (domain repository) backing the Planner tab's
  /// daily record (R-PLAN-001, R-PLAN-004).
  final PlannerRepository plannerRepository;

  /// The durable planner command contract backing the daily record save
  /// (R-PLAN-001, R-PLAN-004).
  final PlannerCommandService plannerCommands;

  // Notes feature.
  final NoteRepository noteRepository;
  final NoteCommandService noteCommands;
  final DeletionService noteDeletion;

  /// The encrypted draft journal (R-NOTE-005). Null when no production draft
  /// cipher is available in this build; note create/edit/list still work, only
  /// crash-recovery drafts are unavailable.
  final NoteDraftJournal? noteDraftJournal;

  // Search feature.
  final SearchService searchService;
  final SavedFiltersStore savedFilters;

  // Life Areas feature.
  final LifeAreaQueryService areaQuery;
  final LifeAreaCommandService areaCommands;

  // Fitness feature.
  /// The fitness read contract backing the Fitness screen (R-FIT-001,
  /// R-FIT-002, R-FIT-004).
  final FitnessQueryService fitnessQuery;

  /// The durable fitness command contract backing create/log/record flows
  /// (R-FIT-001, R-FIT-002).
  final FitnessCommandService fitnessCommands;

  // Insights feature.
  /// The weekly/monthly Insight compute service backing the Insights screen
  /// (R-INSIGHT-001, R-INSIGHT-002, R-INSIGHT-004).
  final PeriodInsightsService insightsService;

  // Notifications feature.
  /// The unified reminder scheduling service backing real OS reminders
  /// (R-NOTIFY-001..006). It owns the rolling-horizon reconciliation loop over
  /// the production [LocalNotificationsTransport]; `main.dart` drives it on
  /// launch and on app resume (R-NOTIFY-004). Plugin-free by construction — all
  /// OS notification work stays behind the [NotificationTransport] port.
  final ReminderService reminderService;

  // Backup / recovery feature.
  /// The recovery-center port backing the Recovery Center surface (R-BACKUP-003,
  /// R-BACKUP-004). Wired in production over the injected [Fbc1Codec] (pointy-
  /// castle Argon2id + AES-256-GCM) and an encrypted `MigrationConnectionOpener`
  /// over the sqlite3mc generation store. Restore always goes through the
  /// existing non-destructive staged generation replace protocol; the live
  /// generation is never modified until the atomic switch. Null only in builds
  /// with no production backup crypto backend.
  final RecoveryCenter? recoveryCenter;

  /// The point-in-time FBC1 exporter over the live encrypted generation
  /// (`R-BACKUP-001`). Null when no production backup crypto backend is wired.
  /// Present here so a future "create a backup" action can seal a recovery
  /// point that [recoveryCenter] then lists and restores; it never mutates the
  /// live store.
  final PointInTimeExporter? backupExporter;

  // Optional cloud sync.
  /// The optional Supabase sync service, or null when sync is disabled in this
  /// build (no `FORGE_SUPABASE_URL`/`FORGE_SUPABASE_ANON_KEY`). When present the
  /// "Account & sync" surface can sign in and run a manual sync; the local-first
  /// store is unaffected either way (R-SYNC-007).
  final SupabaseSyncService? syncService;
}

/// A Recovery-Mode entry. Existing ciphertext/key material is preserved; the UI
/// offers restore/retry rather than any reset.
final class BootstrapRecovery extends BootstrapResult {
  const BootstrapRecovery({required this.info, required this.runtimeFactory});

  final RecoveryModeInfo info;
  final DatabaseRuntimeFactory runtimeFactory;
}

/// Async production entry point that opens the encrypted database and wires the
/// feature services (design.md §4, §16).
///
/// Sequence:
/// 1. Initialize redacting structured logging and the pinned timezone database.
/// 2. Resolve the per-OS app-support base directory.
/// 3. Build production clocks, the UUIDv7 id generator, the sqlite3mc opener,
///    and the local device KeyVault, provisioning a key only on a provably
///    fresh install (R-SEC-001).
/// 4. Open the runtime. On Recovery Mode, return early with the reason.
/// 5. On a ready store, build the command bus + feature command/query services,
///    resolve or seed the active profile and default Life Areas, and return the
///    wired services.
Future<BootstrapResult> bootstrapForge({
  required AppConfig config,
  StructuredLogger? logger,
  String? baseDirectoryOverride,
}) async {
  final Clock clock = const SystemClock.utc();
  final StructuredLogger structuredLogger =
      logger ??
      StructuredLogger(
        utcNow: clock.utcNow,
        sinks: <LocalLogSink>[LocalLogBuffer()],
        minimumLevel: config.environment == ForgeEnvironment.production
            ? LogLevel.info
            : LogLevel.debug,
      );

  // The pinned IANA timezone database makes local-time intent deterministic
  // across runs and devices (R-GEN-004). Initializing it here loads it once.
  final TimeZoneResolver timeZoneResolver =
      TimezonePackageResolver.initialized();
  // Touch the resolver so tree-shaking keeps the initialization side effect and
  // a bad database surfaces at bootstrap rather than first use.
  timeZoneResolver.supportsZone('Etc/UTC');

  final String baseDirectory =
      baseDirectoryOverride ?? await _resolveBaseDirectory();

  final IdGenerator idGenerator = UuidV7Generator(clock: clock);
  final MonotonicClock monotonicClock = SystemMonotonicClock(
    idGenerator: idGenerator,
  );

  final DatabaseRuntimePaths paths = DatabaseRuntimePaths(
    baseDirectory: baseDirectory,
  );

  // The full merged repository factory set: every feature owns its DAO, and the
  // composition root is the one place allowed to assemble them into the single
  // shared unit of work (design.md §16).
  final Map<Type, RepositoryFactory> repositoryFactories =
      <Type, RepositoryFactory>{
        ...taskRepositoryFactories,
        ...areaRepositoryFactories,
        ...noteRepositoryFactories,
        ...habitRepositoryFactories,
        ...focusRepositoryFactories,
        ...learningRepositoryFactories,
        ...goalRepositoryFactories,
        ...roadmapRepositoryFactories,
        ...plannerRepositoryFactories,
        ...fitnessRepositoryFactories,
        ...reminderRepositoryFactories,
        ...searchRepositoryFactories,
      };

  final Sqlite3mcEncryptedStoreOpener opener = Sqlite3mcEncryptedStoreOpener(
    repositoryFactories: repositoryFactories,
  );

  // The device KeyVault custodies the 32-byte database key. The ciphertext
  // probe reports whether any store already depends on the key, so a missing
  // key over existing ciphertext fails closed to Recovery Mode (R-SEC-001).
  final io.File keyFile = io.File(
    '$baseDirectory${io.Platform.pathSeparator}device.key',
  );
  final ActiveGenerationPointer pointer = ActiveGenerationPointer(
    pointerFile: paths.pointerFile,
  );
  bool ciphertextExists() =>
      paths.pointerFile.existsSync() ||
      _generationDatabaseExists(paths, opener.databaseFileName);

  // Select and provision the device-key custodian. The composed decision
  // prefers the OS secret service (libsecret/Keychain/DPAPI/Keystore) when it
  // is reachable and consistent with the current ciphertext, and falls back to
  // the local file vault otherwise. Provisioning happens on the chosen vault
  // and mints a key ONLY when the install is provably fresh.
  final KeyVault keyVault = await _selectAndProvisionKeyVault(
    keyFile: keyFile,
    ciphertextExists: ciphertextExists,
    logger: structuredLogger,
  );
  // Ensure the base directory exists for the pointer/lock files.
  await pointer.pointerFile.parent.create(recursive: true);

  final ForgeDatabaseRuntimeFactory runtimeFactory =
      ForgeDatabaseRuntimeFactory(
        paths: paths,
        keyVault: keyVault,
        opener: opener,
        clock: clock,
        monotonicClock: monotonicClock,
        idGenerator: idGenerator,
        initialGeneration: DatabaseGeneration(
          id: GenerationId(idGenerator.uuidV7()),
          schemaVersion: kForgeSchemaVersion,
        ),
        logger: structuredLogger,
      );

  final DatabaseRuntime runtime = await runtimeFactory.open();
  if (runtime.state != DatabaseRuntimeState.ready) {
    final RecoveryModeInfo info =
        (runtime is ForgeDatabaseRuntime ? runtime.recovery : null) ??
        const RecoveryModeInfo(reason: RecoveryReason.openFailed);
    await runtime.dispose();
    return BootstrapRecovery(info: info, runtimeFactory: runtimeFactory);
  }

  final Sqlite3mcEncryptedStore store = opener.lastOpened!;
  final ForgeSchemaDatabase db = store.database;

  // One command bus over the ready store's unit of work, with the canonical
  // in-transaction search projection registry (R-SEARCH-001).
  final ForgeCommandBus bus = ForgeCommandBus(
    unitOfWork: store.unitOfWork,
    clock: clock,
    afterCommit: AfterCommitDispatcher(),
    searchCoordinator: buildForgeSearchRegistry(),
  );

  final DriftTaskCommandService taskCommands = DriftTaskCommandService(
    bus: bus,
    clock: clock,
    idGenerator: idGenerator,
  );
  final DriftHabitCommandService habitCommands = DriftHabitCommandService(
    bus: bus,
    clock: clock,
    idGenerator: idGenerator,
  );
  final DriftFocusCommandService focusCommands = DriftFocusCommandService(
    bus: bus,
    clock: clock,
    monotonic: monotonicClock,
    idGenerator: idGenerator,
  );
  final DriftLifeAreaCommandService areaCommands = DriftLifeAreaCommandService(
    bus: bus,
    clock: clock,
    idGenerator: idGenerator,
  );

  // ---- Tasks feature ------------------------------------------------------
  // Recurrence reuses the shared bus and the pinned timezone resolver; the
  // deletion kernel + purge preview share one TrashRegistry covering every
  // soft-deletable aggregate wired below (task, note).
  final DriftRecurrenceCommandService taskRecurrence =
      DriftRecurrenceCommandService(
        bus: bus,
        clock: clock,
        idGenerator: idGenerator,
        timeZoneResolver: timeZoneResolver,
      );
  final TrashRegistry trashRegistry = TrashRegistry(<TrashableEntity>[
    TrashableEntity(entityType: 'task', tableName: 'tasks'),
    TrashableEntity(entityType: noteTrashableEntityType, tableName: 'notes'),
  ]);
  final DeletionService taskDeletion = DeletionService(
    bus: bus,
    registry: trashRegistry,
    clock: clock,
    idGenerator: idGenerator,
  );
  final PurgePreviewService taskPurgePreview = PurgePreviewService(
    unitOfWork: store.unitOfWork,
    clock: clock,
    registry: trashRegistry,
  );

  // ---- Learning feature ---------------------------------------------------
  // One read repository instance serves both the Home resume contract and the
  // Learn tab's domain read contract (it implements both); the durable command
  // service backs create/complete/study-session flows (R-LEARN-001..004).
  final LearningReadRepository learningReads = LearningReadRepository(db);
  final DriftLearningCommandService learningCommands =
      DriftLearningCommandService(
        bus: bus,
        clock: clock,
        idGenerator: idGenerator,
      );

  // ---- Goals + roadmap feature -------------------------------------------
  final DriftGoalCommandService goalCommands = DriftGoalCommandService(
    bus: bus,
    clock: clock,
    idGenerator: idGenerator,
  );
  final DriftRoadmapCommandService roadmapCommands = DriftRoadmapCommandService(
    bus: bus,
    clock: clock,
    idGenerator: idGenerator,
  );

  // ---- Planner feature ----------------------------------------------------
  // The read repository loads the single area-scoped daily record for display;
  // the durable command service creates-or-updates its named sections through
  // the shared bus (R-PLAN-001, R-PLAN-004).
  final DriftPlannerCommandService plannerCommands = DriftPlannerCommandService(
    bus: bus,
    clock: clock,
    idGenerator: idGenerator,
  );

  // ---- Notes feature ------------------------------------------------------
  // The deletion kernel repairs inbound wiki-link resolution in the same commit
  // as note trash/restore/purge (R-NOTE-003).
  final DriftNoteCommandService noteCommands = DriftNoteCommandService(
    bus: bus,
    clock: clock,
    idGenerator: idGenerator,
  );

  // Encrypted draft journal (R-NOTE-005). Release a KeyVault lease, derive a
  // domain-separated 256-bit draft sub-key via HKDF-SHA256 (fixed info label
  // "forge-note-draft-v1") so the draft cipher key is independent of the DB
  // key, construct the synchronous AES-256-GCM cipher, then zero the copied
  // bytes and dispose the lease. The sub-key never leaves the cipher instance
  // in memory and is never persisted.
  final KeyLease draftKeyLease = await keyVault.release();
  final Uint8List profileKeyBytes = draftKeyLease.copyBytes();
  final Uint8List draftKeyBytes = _deriveNoteDraftKey(profileKeyBytes);
  // The cipher retains its own defensive copy, so the working buffers can be
  // zeroed immediately.
  final AeadNoteDraftCipher noteDraftCipher = AeadNoteDraftCipher(
    draftKeyBytes,
  );
  profileKeyBytes.fillRange(0, profileKeyBytes.length, 0);
  draftKeyBytes.fillRange(0, draftKeyBytes.length, 0);
  await draftKeyLease.dispose();
  final DriftNoteDraftJournal noteDraftJournal = DriftNoteDraftJournal(
    unitOfWork: store.unitOfWork,
    cipher: noteDraftCipher,
    clock: clock,
  );
  final DeletionService noteDeletion = DeletionService(
    bus: bus,
    registry: trashRegistry,
    clock: clock,
    idGenerator: idGenerator,
    maintenanceHooks: const <String, DeletionMaintenanceHook>{
      noteTrashableEntityType: NoteLinkDeletionMaintenance(),
    },
  );

  // ---- Fitness feature ----------------------------------------------------
  // The read repository loads templates/sessions/measurements from the active
  // generation; the command service writes through the shared bus. Water
  // tracking is optional and disabled by default (R-FIT-003): the store gates
  // water logging but is not surfaced by the V1 Fitness screen.
  final SettingsWaterTrackingStore waterTracking = SettingsWaterTrackingStore(
    db,
    clock,
  );
  final DriftFitnessQueryService fitnessQuery = DriftFitnessQueryService(
    FitnessReadRepository(db),
    waterTracking,
  );
  final DriftFitnessCommandService fitnessCommands = DriftFitnessCommandService(
    bus: bus,
    clock: clock,
    idGenerator: idGenerator,
    waterTracking: waterTracking,
  );

  // ---- Focus feature ------------------------------------------------------
  // One read repository instance serves the Today active-session contract, the
  // per-session detail contract, and the insights combined-time duration
  // contract (it implements all three) (R-FOCUS-003, R-FOCUS-005).
  final FocusReadRepository focusReads = FocusReadRepository(db);

  // ---- Insights feature ---------------------------------------------------
  // Weekly/monthly Insights compose only exported application contracts: the
  // planner's factual-close snapshot and the combined focus/study time union
  // over the already-built focus/learning read repositories (which implement
  // the exported duration contracts). The reproducible close-derived portion is
  // cached in `aggregate_cache`; the interval-unioned time is recomputed live
  // (R-INSIGHT-001, R-INSIGHT-004; design.md §4).
  final PeriodInsightsService insightsService = PeriodInsightsService(
    plannerSummary: PlannerSummaryRepository(PlannerReadRepository(db)),
    combinedTime: CombinedTimeMetricsService(
      focusDuration: focusReads,
      studyDuration: learningReads,
    ),
    cache: DriftAggregateCacheStore(db),
    clock: clock,
  );

  // ---- Notifications feature ---------------------------------------------
  // Bind the real OS notification transport behind the NotificationTransport
  // port, wrap it in the rolling-horizon reconciler, and build the plugin-free
  // ReminderService. The read repository also implements the local-only
  // reconciliation projection writer, so it doubles as `projection` to persist
  // next-fire/delivery/last-diagnostic back onto reminder rows (R-NOTIFY-003).
  // Construction never touches the plugin; the transport initializes lazily and
  // defensively on the first reconcile, so a missing daemon or denied
  // permission degrades to diagnostics rather than blocking bootstrap.
  final LocalNotificationsTransport notificationTransport =
      LocalNotificationsTransport();
  final ReminderReadRepositoryDrift reminderReads = ReminderReadRepositoryDrift(
    db,
  );
  final ReminderService reminderService = ReminderService(
    reads: reminderReads,
    scheduler: HorizonReminderScheduler(notificationTransport),
    transport: notificationTransport,
    resolver: timeZoneResolver,
    clock: clock,
    projection: reminderReads,
  );

  // ---- Backup / recovery feature -----------------------------------------
  // Wire the production FBC1 backup crypto (pointycastle Argon2id + AES-256-GCM)
  // behind the codec, an encrypted MigrationConnectionOpener over the same
  // sqlite3mc store the runtime uses, the point-in-time exporter, and the
  // recovery center over the existing non-destructive staged generation
  // restore (R-BACKUP-001/003/004, design.md §12). The exporter and restore
  // both need the profile cipher key to open the encrypted generation store, so
  // we release ONE KeyVault lease, hand the bytes to the opener (which keeps
  // its own hex-encoded copy), zero the working buffer, and dispose the lease.
  final KeyLease backupKeyLease = await keyVault.release();
  final Uint8List backupKeyBytes = backupKeyLease.copyBytes();
  final EncryptedMigrationConnectionOpener backupOpener =
      EncryptedMigrationConnectionOpener(
        keyBytes: backupKeyBytes,
        storeFileName: opener.databaseFileName,
      );
  backupKeyBytes.fillRange(0, backupKeyBytes.length, 0);
  await backupKeyLease.dispose();

  final Fbc1Codec backupCodec = Fbc1Codec(crypto: PointyCastleBackupCrypto());
  final MigrationLayout backupLayout = MigrationLayout(
    baseDirectory: baseDirectory,
  );
  final PointInTimeExporter backupExporter = PointInTimeExporter(
    opener: backupOpener,
    codec: backupCodec,
    now: clock.utcNow,
    storeFileName: opener.databaseFileName,
    logger: structuredLogger,
  );
  final StagedRestoreService stagedRestore = StagedRestoreService(
    layout: backupLayout,
    opener: backupOpener,
    codec: backupCodec,
    idGenerator: idGenerator,
    storeFileName: opener.databaseFileName,
    logger: structuredLogger,
  );
  final backup_infra.RecoveryCenterService recoveryCenter =
      backup_infra.RecoveryCenterService(
        stagedRestore: stagedRestore,
        recoveryDirectories: <backup_infra.RecoveryDirectory>[
          backup_infra.RecoveryDirectory(
            path: '$baseDirectory/backups',
            source: RecoverySource.userBackup,
          ),
          backup_infra.RecoveryDirectory(
            path: '$baseDirectory/backups/safety',
            source: RecoverySource.safetyBackup,
          ),
        ],
        logger: structuredLogger,
      );

  // Resolve or seed the active profile + default Life Areas, binding the active
  // profile onto the store BEFORE any command peeks the commit sequence.
  final FirstRunProvisioning provisioning = FirstRunProvisioning(
    clock: clock,
    idGenerator: idGenerator,
    areaCommands: areaCommands,
  );
  final ProvisionedProfile provisioned = await provisioning.ensure(
    db: db,
    bindActiveProfile: store.bindActiveProfile,
  );

  // Optional cloud sync (R-SYNC-001/005/007). Constructed ONLY when a backend
  // is configured via dart-define; otherwise sync stays entirely inert and the
  // local-first store is unchanged. The service can then sign in with
  // email/password, provision the account's remote profile, and run a manual
  // push/pull through the replaceable transport + typed remote appliers.
  final SupabaseSyncEnvironment syncEnvironment =
      SupabaseSyncEnvironment.fromEnvironment();
  final SupabaseSyncService? syncService = syncEnvironment.isEnabled
      ? _buildSupabaseSyncService(
          config: syncEnvironment.config!,
          unitOfWork: store.unitOfWork,
          clock: clock,
          idGenerator: idGenerator,
          profileId: provisioned.profileId,
          baseDirectory: baseDirectory,
        )
      : null;
  if (syncService != null) {
    // Restore any persisted session so a signed-in device resumes linked.
    await syncService.restore();
  }

  return BootstrapReady(
    runtime: runtime,
    runtimeFactory: runtimeFactory,
    clock: clock,
    profileId: provisioned.profileId,
    quickCaptureAreaId: provisioned.defaultAreaId,
    layoutStore: SettingsHomeLayoutStore(db, clock),
    taskQuery: DriftTaskQueryService(TaskReadRepository(db)),
    taskCommands: taskCommands,
    learningResume: learningReads,
    learningRepository: learningReads,
    learningCommands: learningCommands,
    habitQuery: DriftHabitQueryService(db),
    habitCommands: habitCommands,
    focusContract: focusReads,
    focusSessionRead: focusReads,
    focusCommands: focusCommands,
    // Tasks feature.
    taskRecurrence: taskRecurrence,
    taskDeletion: taskDeletion,
    taskPurgePreview: taskPurgePreview,
    // Goals + roadmap feature.
    goalRepository: GoalReadRepository(db),
    roadmapRepository: RoadmapReadRepository(db),
    goalCommands: goalCommands,
    roadmapCommands: roadmapCommands,
    // Planner feature.
    plannerRepository: PlannerReadRepository(db),
    plannerCommands: plannerCommands,
    // Notes feature (encrypted draft journal wired via the production AEAD
    // draft cipher over an HKDF-derived, domain-separated sub-key).
    noteRepository: NoteReadRepository(db),
    noteCommands: noteCommands,
    noteDeletion: noteDeletion,
    noteDraftJournal: noteDraftJournal,
    // Search feature.
    searchService: SearchReadRepository(db),
    savedFilters: SettingsSavedFiltersStore(db, clock),
    // Life Areas feature.
    areaQuery: LifeAreaReadRepository(db),
    areaCommands: areaCommands,
    // Fitness feature.
    fitnessQuery: fitnessQuery,
    fitnessCommands: fitnessCommands,
    // Insights feature.
    insightsService: insightsService,
    // Notifications feature.
    reminderService: reminderService,
    // Backup / recovery feature: the recovery center is now wired over the
    // production FBC1 codec + encrypted staged restore, and the point-in-time
    // exporter is available for creating recovery points. Restore always goes
    // through the existing non-destructive staged generation replace protocol.
    recoveryCenter: recoveryCenter,
    backupExporter: backupExporter,
    // Optional cloud sync.
    syncService: syncService,
  );
}

/// Builds the optional Supabase sync service over the ready store's unit of
/// work (R-SYNC-001/003/005/007). The device links its own local profile id as
/// the remote profile id (first-device adoption); the account still owns it
/// server-side via auth.uid(). Only the manifest-allowlisted entities that have
/// a registered typed applier converge on pull; pushing serializes ready outbox
/// groups through the manifest/identity wire boundary.
SupabaseSyncService _buildSupabaseSyncService({
  required SyncBackendConfig config,
  required UnitOfWork unitOfWork,
  required Clock clock,
  required IdGenerator idGenerator,
  required ProfileId profileId,
  required String baseDirectory,
}) {
  final Uri baseUrl = config.url;
  final String anonKey = config.anonKey;
  final http.Client client = http.Client();

  final MutableSupabaseSyncSession session = MutableSupabaseSyncSession();
  final GoTrueAuthClient auth = GoTrueAuthClient(
    baseUrl: baseUrl,
    anonKey: anonKey,
    client: client,
  );
  final FileBackedSecureTokenStore tokenStore = FileBackedSecureTokenStore(
    io.File('$baseDirectory${io.Platform.pathSeparator}sync_session.json'),
  );
  final SupabaseSyncTransport transport = SupabaseSyncTransport(
    baseUrl: baseUrl,
    anonKey: anonKey,
    session: session,
    client: client,
  );
  final SupabaseRemoteProfileGateway gateway = SupabaseRemoteProfileGateway(
    baseUrl: baseUrl,
    anonKey: anonKey,
    session: session,
    client: client,
  );

  // First-device adoption: the remote profile id is this device's local
  // profile id (R-SYNC-001), so the identity translation is stable and known
  // before sign-in.
  final RemoteProfileId remoteProfileId = RemoteProfileId(profileId.value);
  final SyncProfileLink link = SyncProfileLink(
    localProfileId: profileId,
    backend: config.backendId,
    ownerUserId: OwnerUserId(profileId.value),
    remoteProfileId: remoteProfileId,
    state: SyncLinkState.linked,
  );
  final SyncIdentityTranslator identity = SyncIdentityTranslator(link);

  final PullApplyCoordinator pullApply = PullApplyCoordinator(
    unitOfWork: unitOfWork,
    appliers: RemoteApplierRegistry(fitnessRemoteAppliers(profileId)),
    clock: clock,
  );
  final SyncAcknowledgementService acknowledgements =
      SyncAcknowledgementService(unitOfWork: unitOfWork, clock: clock);

  final SupabaseSyncEngine engine = SupabaseSyncEngine(
    unitOfWork: unitOfWork,
    transport: transport,
    pullApply: pullApply,
    acknowledgements: acknowledgements,
    envelopeBuilder: PushEnvelopeBuilder(
      translator: identity,
      manifest: buildForgeReplicationManifestV1(),
    ),
    pullTranslator: PullTranslator(identity),
    clock: clock,
    profileId: profileId,
    deviceId: DeviceId(idGenerator.uuidV7()),
  );

  return SupabaseSyncService(
    auth: auth,
    tokenStore: tokenStore,
    session: session,
    profileGateway: gateway,
    engine: engine,
    clock: clock,
    backendId: config.backendId,
    remoteProfileId: remoteProfileId,
  );
}

/// Fixed HKDF `info` label that domain-separates the note-draft sub-key from
/// the database key (and any future derived keys). Bump the version suffix if
/// the draft cipher's key derivation ever changes.
const String _kNoteDraftKeyInfo = 'forge-note-draft-v1';

/// Derives a dedicated 256-bit note-draft sub-key from the released profile key
/// using HKDF-SHA256 with a fixed `info` label (no salt). This keeps the draft
/// cipher key cryptographically independent of the DB key (R-NOTE-005).
Uint8List _deriveNoteDraftKey(Uint8List profileKey) {
  final pc.HKDFKeyDerivator hkdf = pc.HKDFKeyDerivator(pc.SHA256Digest())
    ..init(
      pc.HkdfParameters(
        profileKey,
        32,
        null,
        Uint8List.fromList(utf8.encode(_kNoteDraftKeyInfo)),
      ),
    );
  final Uint8List out = Uint8List(32);
  hkdf.deriveKey(null, 0, out, 0);
  return out;
}

/// Selects and provisions the device-key custodian using the composed,
/// fail-safe decision rule (R-SEC-001). The overriding invariant is: NEVER mint
/// a fresh key while ciphertext exists — when in doubt, fail closed to Recovery
/// Mode rather than reset an existing encrypted store.
///
/// Decision rule (documented and implemented below):
///   a. A legacy `device.key` file already exists → use [LocalFileKeyVault]. It
///      is authoritative for already-provisioned installs; we do NOT migrate or
///      re-key an existing install into secure storage.
///   b. Otherwise probe the OS secret service by attempting to READ the key:
///      - The store is UNAVAILABLE ([SecureKeyStoreUnavailable]) → fall back to
///        [LocalFileKeyVault] so a headless box with no keyring still opens. A
///        downgrade is safe because the file vault ALSO refuses to mint over
///        existing ciphertext: if ciphertext exists it enters Recovery Mode,
///        and it only mints when the install is provably fresh (no ciphertext).
///      - The store is reachable and HAS the key → use [SecureStorageKeyVault].
///      - The store is reachable, has NO key, but ciphertext EXISTS (a pointer
///        or generation database is present) → Recovery Mode territory. Use
///        [SecureStorageKeyVault]; its [SecureStorageKeyVault.ensureProvisioned]
///        will NOT mint, and a later `release()` fails closed to
///        [KeyVaultState.recoveryRequired].
///      - The store is reachable, has NO key, and NO ciphertext (provably
///        fresh) → use [SecureStorageKeyVault] and provision the key in secure
///        storage.
///
/// The probe itself can only ever DOWNGRADE to the file vault on a genuine
/// [SecureKeyStoreUnavailable]; the "reachable, no key, ciphertext exists" case
/// does not throw from `ensureProvisioned`, so it never downgrades — it stays
/// on the secure vault and fails closed. Combined with the file vault's own
/// no-mint-over-ciphertext guard, a fresh key can never be minted over existing
/// ciphertext by any path.
Future<KeyVault> _selectAndProvisionKeyVault({
  required io.File keyFile,
  required bool Function() ciphertextExists,
  required StructuredLogger logger,
}) async {
  void note(String eventCode) => logger.log(
    level: LogLevel.info,
    component: 'bootstrap.keyvault',
    eventCode: eventCode,
  );

  LocalFileKeyVault buildFileVault() =>
      LocalFileKeyVault(keyFile: keyFile, ciphertextExists: ciphertextExists);

  // (a) An existing legacy key file is authoritative. Never migrate/re-key.
  if (keyFile.existsSync()) {
    note('selected.file.legacy');
    final LocalFileKeyVault vault = buildFileVault();
    await vault.ensureProvisioned();
    return vault;
  }

  // (b) No legacy file: probe the OS secret service and prefer it when usable.
  final FlutterSecureKeyStore store = FlutterSecureKeyStore();
  try {
    // Probe by reading the key. A reachable store returns a value or null; an
    // outage throws SecureKeyStoreUnavailable (caught below to fall back).
    final String? probed = await store.read(
      SecureStorageKeyVault.defaultKeyName,
    );
    note(probed != null ? 'probe.secure.has_key' : 'probe.secure.no_key');

    final SecureStorageKeyVault vault = SecureStorageKeyVault(
      store: store,
      ciphertextExists: ciphertextExists,
    );
    // ensureProvisioned handles every reachable sub-case:
    //  * HAS key                       → available, no write.
    //  * NO key + ciphertext exists    → recoveryRequired, no mint.
    //  * NO key + no ciphertext (fresh)→ mint + write to secure storage.
    // Any mid-flight outage during this step throws SecureKeyStoreUnavailable
    // and is handled by the catch below (fail-safe downgrade).
    await vault.ensureProvisioned();
    note('selected.secure');
    return vault;
  } on SecureKeyStoreUnavailable catch (error) {
    // The secret service is unreachable. Fall back to the local file vault so
    // the app still opens. This downgrade cannot mint over ciphertext: the file
    // vault only mints when provably fresh; with existing ciphertext it enters
    // Recovery Mode instead (R-SEC-001).
    note('selected.file.secure_unavailable');
    logger.log(
      level: LogLevel.warning,
      component: 'bootstrap.keyvault',
      eventCode: 'secure_unavailable',
      attributes: <String, LogAttribute>{
        'detail': LogAttribute.operational(error.message),
      },
    );
    final LocalFileKeyVault vault = buildFileVault();
    await vault.ensureProvisioned();
    return vault;
  }
}

bool _generationDatabaseExists(
  DatabaseRuntimePaths paths,
  String databaseFileName,
) {
  final io.Directory generation = io.Directory(
    paths.generationDirectory(paths.initialGenerationDirectoryName),
  );
  if (!generation.existsSync()) {
    return false;
  }
  return io.File(
    '${generation.path}${io.Platform.pathSeparator}$databaseFileName',
  ).existsSync();
}

/// Resolves the base directory for Forge's local data, choosing a per-platform
/// strategy.
///
/// On mobile (Android/iOS) the process has no meaningful HOME/XDG environment,
/// so the OS-sandboxed application-support directory is resolved via
/// path_provider (`getApplicationSupportDirectory`) — a private, persistent,
/// backup-excluded location the app can always write. On desktop the existing
/// dependency-free environment lookup is kept unchanged, so desktop/Linux
/// behavior and tests are entirely unaffected.
Future<String> _resolveBaseDirectory() async {
  if (io.Platform.isAndroid || io.Platform.isIOS) {
    final io.Directory supportDir = await getApplicationSupportDirectory();
    return '${supportDir.path}${io.Platform.pathSeparator}forge';
  }
  return _resolveAppSupportDirectory();
}

/// Resolves the per-OS application-support directory for Forge's local data on
/// desktop platforms.
///
/// path_provider is intentionally avoided on desktop to keep the dependency
/// surface small;
/// the standard per-OS locations are derived from the environment:
/// * Linux: `$XDG_DATA_HOME` or `~/.local/share`
/// * macOS: `~/Library/Application Support`
/// * Windows: `%APPDATA%`
/// A `forge` subdirectory isolates the app's files.
String _resolveAppSupportDirectory() {
  final Map<String, String> env = io.Platform.environment;
  final String sep = io.Platform.pathSeparator;
  String base;
  if (io.Platform.isWindows) {
    base = env['APPDATA'] ?? env['LOCALAPPDATA'] ?? io.Directory.current.path;
  } else if (io.Platform.isMacOS) {
    final String home = env['HOME'] ?? io.Directory.current.path;
    base = '$home${sep}Library${sep}Application Support';
  } else {
    // Linux and other POSIX desktops.
    final String? xdg = env['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      base = xdg;
    } else {
      final String home = env['HOME'] ?? io.Directory.current.path;
      base = '$home$sep.local${sep}share';
    }
  }
  return '$base${sep}forge';
}
