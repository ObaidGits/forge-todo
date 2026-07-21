import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/fitness/application/fitness_commands.dart';
import 'package:forge/features/fitness/domain/water_event.dart';

import 'fitness_test_support.dart';

/// Optional water tracking behind a disabled-by-default local setting, with
/// preserved neutral units and history (R-FIT-003).
void main() {
  late FitnessHarness harness;

  setUp(() async {
    harness = await FitnessHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  group('disabled by default (R-FIT-003)', () {
    test('the preference defaults to off with no stored row', () async {
      expect(await harness.waterSettings.isEnabled(harness.profileId), isFalse);
      expect(
        await harness.queries.isWaterTrackingEnabled(harness.profileId.value),
        isFalse,
      );
      // No preference row was implicitly written.
      expect(await harness.scalar('SELECT COUNT(*) FROM settings'), 0);
    });

    test(
      'logging is rejected and nothing is persisted while disabled',
      () async {
        final Result<Object> result = await harness.service.logWaterEvent(
          commandId: harness.nextCommandId('w1'),
          profileId: harness.profileId,
          eventId: WaterEventId('water-1'),
          input: const LogWaterEventInput(
            lifeAreaId: 'area-1',
            value: 500,
            unit: 'ml',
            occurredAtUtc: 1000,
          ),
        );

        expect(result, isA<Failed<Object>>());
        expect(
          (result as Failed<Object>).failure.code,
          'fitness.water_disabled',
        );
        expect(await harness.scalar('SELECT COUNT(*) FROM water_events'), 0);
      },
    );
  });

  group('enabled logging (R-FIT-003)', () {
    setUp(() async {
      await harness.waterSettings.setEnabled(harness.profileId, enabled: true);
    });

    test('the toggle is reflected by the query service', () async {
      expect(
        await harness.queries.isWaterTrackingEnabled(harness.profileId.value),
        isTrue,
      );
    });

    test(
      'preserves the entered value/unit and derives a canonical amount',
      () async {
        final Result<Object> result = await harness.service.logWaterEvent(
          commandId: harness.nextCommandId('w1'),
          profileId: harness.profileId,
          eventId: WaterEventId('water-1'),
          input: const LogWaterEventInput(
            lifeAreaId: 'area-1',
            value: 500,
            unit: 'ml',
            occurredAtUtc: 1000,
          ),
        );

        expect(result, isA<Success<Object>>());
        final Map<String, Object?>? row = await harness.firstRow(
          'SELECT entered_value, entered_unit, amount_scaled FROM water_events',
        );
        expect(row!['entered_value'], 500.0);
        expect(row['entered_unit'], 'ml');
        // 500 ml in canonical microlitres.
        expect(row['amount_scaled'], 500000);
      },
    );

    test('preserves a fluid-ounce unit distinct from mass oz', () async {
      await harness.service.logWaterEvent(
        commandId: harness.nextCommandId('w1'),
        profileId: harness.profileId,
        eventId: WaterEventId('water-1'),
        input: const LogWaterEventInput(
          lifeAreaId: 'area-1',
          value: 16,
          unit: 'floz',
          occurredAtUtc: 1000,
        ),
      );

      final List<WaterEvent> history = await harness.queries.waterEventHistory(
        harness.profileId.value,
        fromUtc: 0,
        toUtc: 100000,
      );
      expect(history.single.amount.enteredValue, 16);
      expect(history.single.amount.enteredUnit, 'floz');
      expect(history.single.amount.dimension, 'volume');
    });

    test('history is newest-first and exposes underlying records', () async {
      await harness.service.logWaterEvent(
        commandId: harness.nextCommandId('w1'),
        profileId: harness.profileId,
        eventId: WaterEventId('water-1'),
        input: const LogWaterEventInput(
          lifeAreaId: 'area-1',
          value: 250,
          unit: 'ml',
          occurredAtUtc: 1000,
        ),
      );
      await harness.service.logWaterEvent(
        commandId: harness.nextCommandId('w2'),
        profileId: harness.profileId,
        eventId: WaterEventId('water-2'),
        input: const LogWaterEventInput(
          lifeAreaId: 'area-1',
          value: 1,
          unit: 'l',
          occurredAtUtc: 2000,
        ),
      );

      final List<WaterEvent> history = await harness.queries.waterEventHistory(
        harness.profileId.value,
        fromUtc: 0,
        toUtc: 100000,
      );
      expect(history.map((WaterEvent e) => e.occurredAtUtc), <int>[2000, 1000]);
      expect(history.first.amount.enteredUnit, 'l');
      expect(history.last.amount.enteredUnit, 'ml');
    });

    test('rejects a non-volume unit for a water event', () async {
      final Result<Object> result = await harness.service.logWaterEvent(
        commandId: harness.nextCommandId('bad'),
        profileId: harness.profileId,
        eventId: WaterEventId('water-1'),
        input: const LogWaterEventInput(
          lifeAreaId: 'area-1',
          value: 5,
          unit: 'kg',
          occurredAtUtc: 1000,
        ),
      );

      expect(result, isA<Failed<Object>>());
      expect(
        (result as Failed<Object>).failure.code,
        'fitness.unit_not_volume',
      );
      expect(await harness.scalar('SELECT COUNT(*) FROM water_events'), 0);
    });

    test('replaying the same command id is idempotent (R-GEN-005)', () async {
      final CommandId id = harness.nextCommandId('w-replay');
      const LogWaterEventInput input = LogWaterEventInput(
        lifeAreaId: 'area-1',
        value: 500,
        unit: 'ml',
        occurredAtUtc: 1000,
      );
      final Result<Object> first = await harness.service.logWaterEvent(
        commandId: id,
        profileId: harness.profileId,
        eventId: WaterEventId('water-1'),
        input: input,
      );
      final Result<Object> second = await harness.service.logWaterEvent(
        commandId: id,
        profileId: harness.profileId,
        eventId: WaterEventId('water-1'),
        input: input,
      );

      expect(first, isA<Success<Object>>());
      expect(second, isA<Success<Object>>());
      expect(await harness.scalar('SELECT COUNT(*) FROM water_events'), 1);
    });
  });

  group('history preservation across disable (R-FIT-003)', () {
    test('disabling keeps existing history and blocks new logging', () async {
      await harness.waterSettings.setEnabled(harness.profileId, enabled: true);
      await harness.service.logWaterEvent(
        commandId: harness.nextCommandId('w1'),
        profileId: harness.profileId,
        eventId: WaterEventId('water-1'),
        input: const LogWaterEventInput(
          lifeAreaId: 'area-1',
          value: 500,
          unit: 'ml',
          occurredAtUtc: 1000,
        ),
      );

      // Turn the feature back off.
      await harness.waterSettings.setEnabled(harness.profileId, enabled: false);
      expect(
        await harness.queries.isWaterTrackingEnabled(harness.profileId.value),
        isFalse,
      );

      // Existing history survives the toggle (R-FIT-003).
      final List<WaterEvent> history = await harness.queries.waterEventHistory(
        harness.profileId.value,
        fromUtc: 0,
        toUtc: 100000,
      );
      expect(history.single.amount.enteredValue, 500);
      expect(history.single.amount.enteredUnit, 'ml');

      // New logging is blocked again while disabled.
      final Result<Object> blocked = await harness.service.logWaterEvent(
        commandId: harness.nextCommandId('w2'),
        profileId: harness.profileId,
        eventId: WaterEventId('water-2'),
        input: const LogWaterEventInput(
          lifeAreaId: 'area-1',
          value: 250,
          unit: 'ml',
          occurredAtUtc: 2000,
        ),
      );
      expect(blocked, isA<Failed<Object>>());
      expect(await harness.scalar('SELECT COUNT(*) FROM water_events'), 1);
    });
  });
}
