/// Fitness commands enqueue sync-eligible outbox groups (task 12.1).
///
/// Fitness commands were local-only in Wave 9. This asserts each command now
/// enqueues one semantic outbox group whose operations are ordered
/// parent-before-child, carry the singular replicated entity types, and project
/// only the entered value/unit (never the derived canonical `*_scaled` amount).
///
/// **Validates: Requirements R-FIT-001, R-FIT-002, R-FIT-003, R-SYNC-002**
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/fitness/application/fitness_commands.dart';

import '../../helpers/evidence.dart';
import 'fitness_test_support.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-FITNESS-OUTBOX-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('12.1'),
  requirements: <RequirementId>[
    RequirementId('R-FIT-001'),
    RequirementId('R-FIT-002'),
    RequirementId('R-FIT-003'),
    RequirementId('R-SYNC-002'),
  ],
);

Future<List<Map<String, Object?>>> _outbox(FitnessHarness h) async {
  final List<QueryRow> rows = await h.db
      .customSelect(
        'SELECT entity_type, entity_id, op_kind, group_index, group_id, '
        'payload FROM outbox_mutations ORDER BY group_id, group_index',
      )
      .get();
  return rows.map((QueryRow r) => r.data).toList(growable: false);
}

void main() {
  group('fitness commands enqueue outbox groups', () {
    late FitnessHarness h;

    setUp(() async => h = await FitnessHarness.open());
    tearDown(() async => h.close());

    testWithEvidence(
      _evidence('TEMPLATE-PARENT-BEFORE-CHILD'),
      'creating a template enqueues template then its exercises in order',
      () async {
        final Result<Object?> result = await h.service.createWorkoutTemplate(
          commandId: h.nextCommandId('t1'),
          profileId: h.profileId,
          templateId: WorkoutTemplateId('tmpl-1'),
          input: CreateWorkoutTemplateInput(
            lifeAreaId: h.lifeAreaId.value,
            title: 'Push day',
            rank: 'm',
            exercises: const <TemplateExerciseInput>[
              TemplateExerciseInput(name: 'Bench', rank: 'm', targetSets: 3),
              TemplateExerciseInput(name: 'Dips', rank: 'n'),
            ],
          ),
        );
        expect(result, isA<Success<Object?>>());

        final List<Map<String, Object?>> ops = await _outbox(h);
        expect(ops, hasLength(3));
        // Parent-before-child: template first, then its exercises.
        expect(ops[0]['entity_type'], 'workout_template');
        expect(ops[0]['entity_id'], 'tmpl-1');
        expect(ops[1]['entity_type'], 'template_exercise');
        expect(ops[2]['entity_type'], 'template_exercise');
        // One semantic group, contiguous 0-based indices.
        expect(
          ops.map((Map<String, Object?> o) => o['group_id']).toSet(),
          hasLength(1),
        );
        expect(
          ops.map((Map<String, Object?> o) => o['group_index']).toList(),
          <int>[0, 1, 2],
        );
        for (final Map<String, Object?> op in ops) {
          expect(op['op_kind'], 'insert');
        }
      },
    );

    testWithEvidence(
      _evidence('SESSION-HIERARCHY-ORDER'),
      'logging a session enqueues session, exercise log, then set log in order',
      () async {
        final Result<Object?> result = await h.service.logWorkoutSession(
          commandId: h.nextCommandId('s1'),
          profileId: h.profileId,
          sessionId: WorkoutSessionId('sess-1'),
          input: LogWorkoutSessionInput(
            lifeAreaId: h.lifeAreaId.value,
            title: 'Morning lift',
            startedAtUtc: 1000,
            exercises: const <ExerciseLogInput>[
              ExerciseLogInput(
                name: 'Squat',
                rank: 'm',
                sets: <SetLogInput>[
                  SetLogInput(
                    rank: 'm',
                    reps: 5,
                    weightValue: 135,
                    weightUnit: 'lb',
                  ),
                ],
              ),
            ],
          ),
        );
        expect(result, isA<Success<Object?>>());

        final List<Map<String, Object?>> ops = await _outbox(h);
        expect(
          ops.map((Map<String, Object?> o) => o['entity_type']).toList(),
          <String>['workout_session', 'exercise_log', 'set_log'],
        );

        // The set-log payload preserves the entered value/unit and does NOT
        // carry the derived canonical scaled amount (R-FIT-002).
        final Map<String, Object?> setPayload =
            jsonDecode(ops[2]['payload']! as String) as Map<String, Object?>;
        expect(setPayload['weight_entered'], 135);
        expect(setPayload['weight_unit'], 'lb');
        expect(setPayload.containsKey('weight_scaled'), isFalse);
      },
    );

    testWithEvidence(
      _evidence('MEASUREMENT-ENQUEUED'),
      'recording a body measurement enqueues a single replicated operation',
      () async {
        final Result<Object?> result = await h.service.recordBodyMeasurement(
          commandId: h.nextCommandId('m1'),
          profileId: h.profileId,
          measurementId: BodyMeasurementId('meas-1'),
          input: RecordBodyMeasurementInput(
            lifeAreaId: h.lifeAreaId.value,
            value: 80.5,
            unit: 'kg',
            measuredAtUtc: 2000,
          ),
        );
        expect(result, isA<Success<Object?>>());

        final List<Map<String, Object?>> ops = await _outbox(h);
        expect(ops, hasLength(1));
        expect(ops[0]['entity_type'], 'body_measurement');
        final Map<String, Object?> payload =
            jsonDecode(ops[0]['payload']! as String) as Map<String, Object?>;
        expect(payload['entered_value'], 80.5);
        expect(payload['entered_unit'], 'kg');
        expect(payload.containsKey('value_scaled'), isFalse);
      },
    );

    testWithEvidence(
      _evidence('WATER-EVENT-ENQUEUED'),
      'an enabled water event enqueues a replicated operation (R-FIT-003)',
      () async {
        await h.waterSettings.setEnabled(h.profileId, enabled: true);
        final Result<Object?> result = await h.service.logWaterEvent(
          commandId: h.nextCommandId('w1'),
          profileId: h.profileId,
          eventId: WaterEventId('water-1'),
          input: _waterInput(h.lifeAreaId.value),
        );
        expect(result, isA<Success<Object?>>());

        final List<Map<String, Object?>> ops = await _outbox(h);
        expect(ops, hasLength(1));
        expect(ops[0]['entity_type'], 'water_event');
        final Map<String, Object?> payload =
            jsonDecode(ops[0]['payload']! as String) as Map<String, Object?>;
        expect(payload['entered_value'], 500);
        expect(payload['entered_unit'], 'ml');
        expect(payload.containsKey('amount_scaled'), isFalse);
      },
    );
  });
}

/// Small helper to build a fixed water input.
LogWaterEventInput _waterInput(String lifeAreaId) => LogWaterEventInput(
  lifeAreaId: lifeAreaId,
  value: 500,
  unit: 'ml',
  occurredAtUtc: 3000,
);
