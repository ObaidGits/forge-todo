import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/command/after_commit_dispatcher.dart';
import 'package:forge/app/infrastructure/database/command/command_bus.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/learning/application/learning_commands.dart';
import 'package:forge/features/learning/domain/learning_item_type.dart';
import 'package:forge/features/learning/domain/learning_policies.dart';
import 'package:forge/features/learning/domain/learning_resource_type.dart';
import 'package:forge/features/learning/domain/learning_statistics.dart';
import 'package:forge/features/learning/domain/study_session.dart';
import 'package:forge/features/learning/domain/study_session_event_kind.dart';
import 'package:forge/features/learning/infrastructure/learning_command_service_drift.dart';
import 'package:forge/features/learning/infrastructure/learning_read_repository.dart';
import 'package:forge/features/learning/infrastructure/learning_repository_factories.dart';
import 'package:forge/features/learning/infrastructure/learning_search_projector.dart';
import 'package:forge/features/search/application/search_projector.dart';
import 'package:forge/features/search/infrastructure/search_projection_registry.dart';
import 'package:forge/features/search/infrastructure/search_repository_factories.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_id_generator.dart';
import '../schema/schema_test_database.dart';
import '../tasks/task_test_support.dart';

/// Study-session **restart** integration proof (R-LEARN-002/003/004/005).
///
/// The in-memory `LearningHarness` proves correction/supersession, statistics
/// and interval-union within one process session. This suite closes the last
/// gap for task 6.6: it wires the learning command service and read model over
/// a **file-backed** Drift store, then simulates a real process restart by
/// closing and reopening the whole stack over the *same persisted file* — the
/// same technique the durable-command property test uses.
///
/// After the restart the read model re-projects purely from persisted rows, so
/// this asserts that:
///  * logged study sessions and their append-only events survive restart
///    (R-LEARN-002);
///  * resume resolution still identifies the last incomplete studied item after
///    restart, without mutating anything (R-LEARN-003);
///  * a correction applied before restart is still the sole current version and
///    the prior facts remain immutably retained (R-LEARN-002);
///  * derived progress and interval-union statistics recompute to the same
///    values after restart, counting a superseded version once at most
///    (R-LEARN-004, R-LEARN-005).
///
/// **Validates: Requirements R-LEARN-002, R-LEARN-003, R-LEARN-004, R-LEARN-005**
void main() {
  late Directory dir;
  late String storePath;
  late _RestartableLearning app;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('forge_learn_restart_');
    storePath = '${dir.path}/store.sqlite';
    app = await _RestartableLearning.open(storePath, freshProfile: true);
  });

  tearDown(() async {
    await app.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  int us(DateTime t) => t.microsecondsSinceEpoch;

  test('[TEST-LEARN-RESTART-001][MVP][TASK-6.6]'
      '[R-LEARN-002,R-LEARN-003,R-LEARN-004,R-LEARN-005] '
      'study sessions, resume, corrections and statistics survive a process '
      'restart via pure re-projection', () async {
    // --- Session before restart --------------------------------------------
    final String resource = await app.createResource('Rust Book');
    final String item1 = await app.addItem(resource, 'Ownership', seed: 'i1');
    final String item2 = await app.addItem(resource, 'Borrowing', seed: 'i2');

    // Two overlapping study sessions on item1; union is 09:00–10:30 = 5400s.
    final String logical1 = await app.logSession(
      resource,
      start: DateTime.utc(2024, 6, 1, 9),
      end: DateTime.utc(2024, 6, 1, 10),
      itemId: item1,
      seed: 'ss1',
    );
    await app.logSession(
      resource,
      start: DateTime.utc(2024, 6, 1, 9, 30),
      end: DateTime.utc(2024, 6, 1, 10, 30),
      itemId: item1,
      seed: 'ss2',
    );
    // Complete item1 so resume advances to item2 after restart.
    await app.completeItem(item1, at: us(DateTime.utc(2024, 6, 1, 10, 45)));

    // Correct the first session's note before restart; the prior facts must
    // remain retained and immutable across the restart.
    await app.correct(
      logical1,
      note: 'corrected before restart',
      reason: 'typo',
      seed: 'corr1',
    );

    final int rangeStart = us(DateTime.utc(2024, 6, 1));
    final int rangeEnd = us(DateTime.utc(2024, 6, 2));

    final LearningStatistics before = await app.reads.statistics(
      app.profileId,
      rangeStartUtc: rangeStart,
      rangeEndUtc: rangeEnd,
    );
    final ResumePoint resumeBefore = await app.reads.resumePoint(
      app.profileId,
      LearningResourceId(resource),
    );
    // Union of the two overlapping sessions, counted once.
    expect(before.studiedDurationSec, 5400);
    expect(before.sessionCount, 2);
    expect(before.completedItems, 1);
    expect(resumeBefore.itemId, item2);

    // --- Simulate a process restart: close and reopen the same file. -------
    await app.close();
    app = await _RestartableLearning.open(storePath, freshProfile: false);

    // 1) Sessions and their append-only lifecycle events survived
    //    (R-LEARN-002). The corrected session is the sole current version 2,
    //    and version 1 with its original facts is immutably retained.
    final List<StudySession> current = await app.reads.currentSessionsOf(
      app.profileId,
      LearningResourceId(resource),
    );
    expect(current.length, 2, reason: 'both logged sessions persist');
    final int totalRows = await app.scalar(
      'SELECT COUNT(*) FROM study_sessions WHERE logical_id = ?',
      <Object?>[logical1],
    );
    expect(totalRows, 2, reason: 'corrected session retains its prior row');
    final Map<String, Object?>? priorFacts = await app.firstRow(
      'SELECT note, is_current FROM study_sessions '
      'WHERE logical_id = ? AND version = 1',
      <Object?>[logical1],
    );
    expect(priorFacts!['is_current'], 0);
    final List<StudySessionEvent> events = await app.reads.sessionEvents(
      app.profileId,
      logical1,
    );
    expect(
      events.map((StudySessionEvent e) => e.kind).toList(),
      <StudySessionEventKind>[
        StudySessionEventKind.logged,
        StudySessionEventKind.corrected,
      ],
    );

    // 2) Resume resolution after restart still points at the incomplete item,
    //    purely projected, without mutating any learning row (R-LEARN-003).
    final int itemsRevSum = await app.scalar(
      'SELECT COUNT(*) FROM learning_items WHERE completed_at_utc IS NOT NULL',
    );
    final ResumePoint resumeAfter = await app.reads.resumePoint(
      app.profileId,
      LearningResourceId(resource),
    );
    expect(resumeAfter.itemId, item2);
    // A second read does not change anything.
    await app.reads.resumePoint(app.profileId, LearningResourceId(resource));
    expect(
      await app.scalar(
        'SELECT COUNT(*) FROM learning_items '
        'WHERE completed_at_utc IS NOT NULL',
      ),
      itemsRevSum,
    );

    // 3) Interval-union statistics recompute to the identical values after
    //    restart (R-LEARN-004, R-LEARN-005).
    final LearningStatistics after = await app.reads.statistics(
      app.profileId,
      rangeStartUtc: rangeStart,
      rangeEndUtc: rangeEnd,
    );
    expect(after.studiedDurationSec, before.studiedDurationSec);
    expect(after.sessionCount, before.sessionCount);
    expect(after.completedItems, before.completedItems);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('[TEST-LEARN-RESTART-002][MVP][TASK-6.6][R-LEARN-005] '
      'a correction issued after restart still supersedes the pre-restart '
      'session and statistics reflect only the current version', () async {
    final String resource = await app.createResource('Zero to One');
    final String logical = await app.logSession(
      resource,
      start: DateTime.utc(2024, 6, 1, 9),
      end: DateTime.utc(2024, 6, 1, 10),
      seed: 'ss1',
    );

    await app.close();
    app = await _RestartableLearning.open(storePath, freshProfile: false);

    // Correct the pre-restart session down to 30 minutes after reopening.
    await app.correct(
      logical,
      endedAt: DateTime.utc(2024, 6, 1, 9, 30),
      reason: 'ran shorter',
      seed: 'corr-after',
    );

    final LearningStatistics stats = await app.reads.statistics(
      app.profileId,
      rangeStartUtc: us(DateTime.utc(2024, 6, 1)),
      rangeEndUtc: us(DateTime.utc(2024, 6, 2)),
    );
    expect(stats.studiedDurationSec, 1800);
    expect(stats.sessionCount, 1);

    final int rows = await app.scalar(
      'SELECT COUNT(*) FROM study_sessions WHERE logical_id = ?',
      <Object?>[logical],
    );
    expect(rows, 2, reason: 'prior version retained after post-restart fix');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// A learning command/read stack bound to a reopenable file-backed Drift store.
final class _RestartableLearning {
  _RestartableLearning._(this._db, this.profileId, this._service, this.reads);

  final ForgeSchemaDatabase _db;
  final ProfileId profileId;
  final DriftLearningCommandService _service;
  final LearningReadRepository reads;

  int _cmd = 0;
  CommandId _next(String? seed) => CommandId('cmd-${seed ?? (_cmd++)}');

  static Future<_RestartableLearning> open(
    String storePath, {
    required bool freshProfile,
  }) async {
    final ForgeSchemaDatabase db = ForgeSchemaDatabase(
      NativeDatabase(File(storePath)),
    );
    const String profileId = 'profile-1';
    if (freshProfile) {
      await insertProfile(db);
      await insertLifeArea(db, profileId, id: 'area-1');
    }
    final FakeClock clock = FakeClock(initialUtc: DateTime.utc(2024, 6, 1, 12));
    final FakeIdGenerator ids = FakeIdGenerator.sequential();
    final SearchProjectionRegistry registry = SearchProjectionRegistry(
      const <SearchProjector>[LearningSearchProjector()],
    );
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => profileId,
      repositoryFactories: <Type, RepositoryFactory>{
        ...learningRepositoryFactories,
        ...searchRepositoryFactories,
      },
    );
    final ForgeCommandBus bus = ForgeCommandBus(
      unitOfWork: unitOfWork,
      clock: clock,
      afterCommit: AfterCommitDispatcher(),
      searchCoordinator: registry,
    );
    return _RestartableLearning._(
      db,
      ProfileId(profileId),
      DriftLearningCommandService(bus: bus, clock: clock, idGenerator: ids),
      LearningReadRepository(db),
    );
  }

  Future<void> close() => _db.close();

  CommittedCommandResult _ok(Result<CommittedCommandResult> r) => switch (r) {
    Success<CommittedCommandResult>(value: final CommittedCommandResult v) => v,
    Failed<CommittedCommandResult>(failure: final Failure f) =>
      throw StateError('command failed: ${f.code}'),
  };

  Future<int> scalar(
    String sql, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          sql,
          variables: <Variable<Object>>[
            for (final Object? a in args) Variable<Object>(a as Object),
          ],
        )
        .get();
    return rows.single.data.values.first as int;
  }

  Future<Map<String, Object?>?> firstRow(
    String sql, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final List<QueryRow> rows = await _db
        .customSelect(
          sql,
          variables: <Variable<Object>>[
            for (final Object? a in args) Variable<Object>(a as Object),
          ],
        )
        .get();
    return rows.isEmpty ? null : rows.first.data;
  }

  Future<String> createResource(String title) async {
    final CommittedCommandResult r = _ok(
      await _service.createResource(
        commandId: _next('res'),
        profileId: profileId,
        input: CreateResourceInput(
          lifeAreaId: 'area-1',
          title: title,
          type: LearningResourceType.book,
        ),
      ),
    );
    return (jsonDecode(r.resultPayload!) as Map<String, Object?>)['resource_id']
        as String;
  }

  Future<String> addItem(
    String resourceId,
    String title, {
    required String seed,
  }) async {
    final CommittedCommandResult r = _ok(
      await _service.addItem(
        commandId: _next(seed),
        profileId: profileId,
        input: AddItemInput(
          resourceId: resourceId,
          title: title,
          type: LearningItemType.lesson,
        ),
      ),
    );
    return (jsonDecode(r.resultPayload!) as Map<String, Object?>)['item_id']
        as String;
  }

  Future<void> completeItem(String itemId, {required int at}) async {
    _ok(
      await _service.completeItem(
        commandId: _next('complete-$itemId'),
        profileId: profileId,
        itemId: itemId,
        completedAtUtc: at,
      ),
    );
  }

  Future<String> logSession(
    String resourceId, {
    required DateTime start,
    required DateTime end,
    String? itemId,
    required String seed,
  }) async {
    final CommittedCommandResult r = _ok(
      await _service.logStudySession(
        commandId: _next(seed),
        profileId: profileId,
        input: LogStudySessionInput(
          resourceId: resourceId,
          startedAtUtc: start.microsecondsSinceEpoch,
          endedAtUtc: end.microsecondsSinceEpoch,
          itemId: itemId,
        ),
      ),
    );
    return RegExp(
      '"logical_id":"([^"]+)"',
    ).firstMatch(r.resultPayload!)!.group(1)!;
  }

  Future<void> correct(
    String logicalId, {
    String? note,
    DateTime? endedAt,
    String? reason,
    required String seed,
  }) async {
    _ok(
      await _service.correctStudySession(
        commandId: _next(seed),
        profileId: profileId,
        input: CorrectStudySessionInput(
          logicalId: logicalId,
          endedAtUtc: endedAt?.microsecondsSinceEpoch,
          note: note == null ? null : FieldEdit<String>.set(note),
          reason: reason,
        ),
      ),
    );
  }
}
