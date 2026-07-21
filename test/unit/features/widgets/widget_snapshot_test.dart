/// Widget snapshot builder, redaction, freshness, versioning, and codec tests.
///
/// Covers the snapshot-side obligations of the widget bridge foundation:
/// redaction under app-lock/privacy (R-WIDGET-004), a versioned local-only
/// projection the container renders without the encrypted database
/// (R-WIDGET-002), and an honest freshness/stale stamp (R-WIDGET-003).
///
/// **Validates: Requirements R-WIDGET-002, R-WIDGET-003, R-WIDGET-004**
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/widgets/application/widget_snapshot_builder.dart';
import 'package:forge/features/widgets/domain/widget_snapshot.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';

import '../../../helpers/helpers.dart';

EvidenceMetadata _evidence(String suffix, List<String> requirements) =>
    EvidenceMetadata(
      evidenceId: EvidenceId('WIDGET-SNAPSHOT-$suffix'),
      releaseTag: ReleaseTag.v1,
      taskId: SpecTaskId('11.1'),
      requirements: <RequirementId>[
        for (final String requirement in requirements)
          RequirementId(requirement),
      ],
    );

List<WidgetSnapshotItem> _items(int count) => <WidgetSnapshotItem>[
  for (int i = 0; i < count; i += 1)
    WidgetSnapshotItem(id: 'task-$i', title: 'Task $i', isComplete: i.isEven),
];

void main() {
  final ProfileId profile = ProfileId('profile-1');

  group('WidgetSnapshotBuilder redaction (R-WIDGET-004)', () {
    testWithEvidence(
      _evidence('REDACT-LOCKED', <String>['R-WIDGET-004']),
      'a snapshot built while content is hidden carries no items and is marked '
      'redacted',
      () {
        final WidgetSnapshotBuilder builder = WidgetSnapshotBuilder(
          clock: FakeClock(initialUtc: DateTime.utc(2024, 6, 1, 12)),
        );
        final WidgetSnapshot snapshot = builder.build(
          surface: WidgetSurface.todayTasks,
          profileId: profile,
          items: _items(5),
          contentVisible: false,
        );
        expect(snapshot.redacted, isTrue);
        expect(snapshot.items, isEmpty);
        expect(snapshot.version, WidgetSnapshot.currentVersion);
      },
    );

    testWithEvidence(
      _evidence('REVEAL-UNLOCKED', <String>['R-WIDGET-002', 'R-WIDGET-004']),
      'a snapshot built while content is visible carries clamped, bounded items',
      () {
        final WidgetSnapshotBuilder builder = WidgetSnapshotBuilder(
          clock: FakeClock(initialUtc: DateTime.utc(2024, 6, 1, 12)),
        );
        final WidgetSnapshot snapshot = builder.build(
          surface: WidgetSurface.todayTasks,
          profileId: profile,
          items: _items(3),
          contentVisible: true,
        );
        expect(snapshot.redacted, isFalse);
        expect(snapshot.items, hasLength(3));
        expect(snapshot.items.first.title, 'Task 0');
      },
    );
  });

  group('WidgetSnapshotBuilder bounds (R-WIDGET-002)', () {
    testWithEvidence(
      _evidence('BOUNDS', <String>['R-WIDGET-002']),
      'items are truncated to the cap and long text is clamped',
      () {
        final WidgetSnapshotBuilder builder = WidgetSnapshotBuilder(
          clock: FakeClock(initialUtc: DateTime.utc(2024, 6, 1, 12)),
        );
        final String longTitle = 'x' * 200;
        final WidgetSnapshot snapshot = builder.build(
          surface: WidgetSurface.todayTasks,
          profileId: profile,
          items: <WidgetSnapshotItem>[
            for (int i = 0; i < 50; i += 1)
              WidgetSnapshotItem(id: 'id-$i', title: longTitle),
          ],
          contentVisible: true,
        );
        expect(snapshot.items, hasLength(WidgetSnapshot.maxItems));
        for (final WidgetSnapshotItem item in snapshot.items) {
          expect(
            item.title.length,
            lessThanOrEqualTo(WidgetSnapshot.maxTextLength),
          );
        }
      },
    );
  });

  group('WidgetSnapshot freshness (R-WIDGET-003)', () {
    testWithEvidence(
      _evidence('FRESHNESS', <String>['R-WIDGET-003']),
      'a snapshot is fresh within its threshold and stale beyond it',
      () {
        final FakeClock clock = FakeClock(initialUtc: DateTime.utc(2024, 6, 1));
        final WidgetSnapshotBuilder builder = WidgetSnapshotBuilder(
          clock: clock,
          defaultStaleness: const Duration(minutes: 30),
        );
        final WidgetSnapshot snapshot = builder.build(
          surface: WidgetSurface.todayTasks,
          profileId: profile,
          items: _items(1),
          contentVisible: true,
        );
        final int gen = snapshot.generatedAtUtcMicros;
        const int minute = 60 * 1000000;
        expect(snapshot.freshnessAt(gen), WidgetFreshness.fresh);
        expect(snapshot.freshnessAt(gen + 29 * minute), WidgetFreshness.fresh);
        expect(snapshot.freshnessAt(gen + 30 * minute), WidgetFreshness.fresh);
        expect(snapshot.freshnessAt(gen + 31 * minute), WidgetFreshness.stale);
        // Clock skew (a future read) is treated as fresh, never wrongly stale.
        expect(snapshot.freshnessAt(gen - minute), WidgetFreshness.fresh);
      },
    );
  });

  group('WidgetSnapshotCodec version safety (R-WIDGET-002)', () {
    testWithEvidence(
      _evidence('CODEC-ROUNDTRIP', <String>['R-WIDGET-002']),
      'canonical encode/decode round-trips and is deterministic',
      () {
        final WidgetSnapshotBuilder builder = WidgetSnapshotBuilder(
          clock: FakeClock(initialUtc: DateTime.utc(2024, 6, 1, 12)),
        );
        final WidgetSnapshot snapshot = builder.build(
          surface: WidgetSurface.habitChecklist,
          profileId: profile,
          items: _items(4),
          contentVisible: true,
        );
        final String encoded = WidgetSnapshotCodec.encode(snapshot);
        expect(WidgetSnapshotCodec.encode(snapshot), encoded);
        expect(WidgetSnapshotCodec.decode(encoded), snapshot);
      },
    );

    testWithEvidence(
      _evidence('CODEC-FALLBACK', <String>['R-WIDGET-002', 'R-WIDGET-003']),
      'a newer format version or malformed bytes decode to null (safe fallback)',
      () {
        expect(WidgetSnapshotCodec.decode('not json'), isNull);
        expect(WidgetSnapshotCodec.decode('[]'), isNull);
        expect(
          WidgetSnapshotCodec.decode(
            '{"version":999,"surface":"today_tasks","profile_id":"p",'
            '"generated_at_utc_micros":1,"staleness_threshold_seconds":60,'
            '"redacted":false,"items":[]}',
          ),
          isNull,
        );
      },
    );
  });

  group('WidgetSnapshotBuilder property: redaction hides all content', () {
    testWithEvidence(
      _evidence('PROP-REDACTION', <String>['R-WIDGET-002', 'R-WIDGET-004']),
      'across random content and visibility, a hidden snapshot never leaks '
      'items or counts and a visible one never exceeds bounds',
      () {
        for (int seed = 0; seed < 500; seed += 1) {
          final Random rng = Random(seed);
          final FakeClock clock = FakeClock(
            initialUtc: DateTime.utc(2024, 1, 1).add(Duration(minutes: seed)),
          );
          final WidgetSnapshotBuilder builder = WidgetSnapshotBuilder(
            clock: clock,
          );
          final bool visible = rng.nextBool();
          final int count = rng.nextInt(30);
          final List<WidgetSnapshotItem> items = <WidgetSnapshotItem>[
            for (int i = 0; i < count; i += 1)
              WidgetSnapshotItem(
                id: 'e$seed-$i',
                title: 'secret-${rng.nextInt(1 << 20)}',
                subtitle: rng.nextBool() ? 'due-${rng.nextInt(999)}' : null,
                isComplete: rng.nextBool(),
              ),
          ];
          final WidgetSurface surface =
              WidgetSurface.values[rng.nextInt(WidgetSurface.values.length)];

          final WidgetSnapshot snapshot = builder.build(
            surface: surface,
            profileId: profile,
            items: items,
            contentVisible: visible,
          );

          // Versioned always.
          expect(snapshot.version, WidgetSnapshot.currentVersion);
          // The encoded bytes are what the container sees.
          final String encoded = WidgetSnapshotCodec.encode(snapshot);

          if (!visible) {
            expect(snapshot.redacted, isTrue, reason: 'seed=$seed');
            expect(snapshot.items, isEmpty, reason: 'seed=$seed');
            // No item content (titles) can appear in the encoded payload.
            for (final WidgetSnapshotItem item in items) {
              expect(
                encoded.contains(item.title),
                isFalse,
                reason: 'seed=$seed leaked ${item.title}',
              );
            }
          } else {
            expect(snapshot.redacted, isFalse, reason: 'seed=$seed');
            expect(
              snapshot.items.length,
              lessThanOrEqualTo(WidgetSnapshot.maxItems),
              reason: 'seed=$seed',
            );
            for (final WidgetSnapshotItem item in snapshot.items) {
              expect(
                item.title.length,
                lessThanOrEqualTo(WidgetSnapshot.maxTextLength),
              );
            }
          }
        }
      },
    );
  });
}
