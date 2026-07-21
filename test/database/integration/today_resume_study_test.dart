import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/home/application/home_content.dart';

import 'wave5_integration_support.dart';

/// Real Drift-backed integration proof that Today surfaces the active study
/// recommendation from real learning data through the learning feature's
/// exported resume contract, identifying the last incomplete item **without
/// changing it** (R-HOME-001, R-LEARN-003).
///
/// **Validates: Requirements R-HOME-001, R-LEARN-003**
void main() {
  late Wave5IntegrationHarness h;

  // Clock pinned to 2024-06-15 09:00 UTC by the harness.
  const String planningDate = '2024-06-15';
  final int dayStart = DateTime.utc(2024, 6, 15).microsecondsSinceEpoch;
  final int now = DateTime.utc(2024, 6, 15, 9).microsecondsSinceEpoch;

  Future<HomeTodayContent> today() => h.homeQuery.today(
    profileId: h.profileId,
    currentPlanningDate: planningDate,
    dayStartUtcMicros: dayStart,
    nowUtcMicros: now,
  );

  setUp(() async {
    h = await Wave5IntegrationHarness.open();
  });

  tearDown(() async {
    await h.close();
  });

  test(
    'Today resumes the last studied resource at its incomplete item',
    () async {
      final String resource = await h.createResource('Rust Book', seed: 'res');
      final String item1 = await h.addItem(resource, 'Ownership', seed: 'i1');
      await h.addItem(resource, 'Borrowing', seed: 'i2');

      // The user studied item1 earlier today; it is still incomplete.
      await h.logStudySession(
        resource,
        startedAtUtc: DateTime.utc(2024, 6, 15, 8).microsecondsSinceEpoch,
        endedAtUtc: DateTime.utc(2024, 6, 15, 8, 30).microsecondsSinceEpoch,
        itemId: item1,
        seed: 'ss1',
      );

      final HomeTodayContent content = await today();
      final StudyRecommendationSlot? study = content.studyRecommendation;
      expect(study, isNotNull);
      expect(study!.resourceId, resource);
      expect(study.title, 'Rust Book');
      expect(study.resumeItemId, item1);
      expect(study.resumeItemTitle, 'Ownership');
      expect(study.reason, 'last_studied');
    },
  );

  test('surfacing the recommendation does not mutate any learning row', () async {
    final String resource = await h.createResource('Rust Book', seed: 'res');
    final String item1 = await h.addItem(resource, 'Ownership', seed: 'i1');
    await h.addItem(resource, 'Borrowing', seed: 'i2');
    await h.logStudySession(
      resource,
      startedAtUtc: DateTime.utc(2024, 6, 15, 8).microsecondsSinceEpoch,
      endedAtUtc: DateTime.utc(2024, 6, 15, 8, 30).microsecondsSinceEpoch,
      itemId: item1,
      seed: 'ss1',
    );

    // Snapshot the authoritative rows before Today reads.
    final int resourceRev = await h.scalar(
      'SELECT revision FROM courses WHERE id = ?',
      <Object?>[resource],
    );
    final int sessionCount = await h.scalar(
      'SELECT COUNT(*) FROM study_sessions',
    );
    final int completedItems = await h.scalar(
      'SELECT COUNT(*) FROM learning_items WHERE completed_at_utc IS NOT NULL',
    );

    // Read Today twice — resume must be a pure projection.
    await today();
    final StudyRecommendationSlot? study = (await today()).studyRecommendation;

    expect(study, isNotNull);
    expect(study!.resumeItemId, item1);
    expect(
      await h.scalar('SELECT revision FROM courses WHERE id = ?', <Object?>[
        resource,
      ]),
      resourceRev,
    );
    expect(await h.scalar('SELECT COUNT(*) FROM study_sessions'), sessionCount);
    expect(
      await h.scalar(
        'SELECT COUNT(*) FROM learning_items WHERE completed_at_utc IS NOT NULL',
      ),
      completedItems,
    );
  });

  test(
    'completing the studied item advances the recommendation to the next item',
    () async {
      final String resource = await h.createResource('Rust Book', seed: 'res');
      final String item1 = await h.addItem(resource, 'Ownership', seed: 'i1');
      final String item2 = await h.addItem(resource, 'Borrowing', seed: 'i2');
      await h.logStudySession(
        resource,
        startedAtUtc: DateTime.utc(2024, 6, 15, 8).microsecondsSinceEpoch,
        endedAtUtc: DateTime.utc(2024, 6, 15, 8, 30).microsecondsSinceEpoch,
        itemId: item1,
        seed: 'ss1',
      );

      await h.completeItem(
        item1,
        at: DateTime.utc(2024, 6, 15, 8, 45).microsecondsSinceEpoch,
        seed: 'c1',
      );

      final StudyRecommendationSlot? study =
          (await today()).studyRecommendation;
      expect(study, isNotNull);
      expect(study!.resumeItemId, item2);
      expect(study.resumeItemTitle, 'Borrowing');
    },
  );

  test('a fully completed resource yields no recommendation', () async {
    final String resource = await h.createResource('Rust Book', seed: 'res');
    final String item1 = await h.addItem(resource, 'Ownership', seed: 'i1');
    await h.logStudySession(
      resource,
      startedAtUtc: DateTime.utc(2024, 6, 15, 8).microsecondsSinceEpoch,
      endedAtUtc: DateTime.utc(2024, 6, 15, 8, 30).microsecondsSinceEpoch,
      itemId: item1,
      seed: 'ss1',
    );
    await h.completeItem(
      item1,
      at: DateTime.utc(2024, 6, 15, 8, 45).microsecondsSinceEpoch,
      seed: 'c1',
    );

    expect((await today()).studyRecommendation, isNull);
  });

  test('with no learning data Today has no study recommendation', () async {
    expect((await today()).studyRecommendation, isNull);
  });
}
