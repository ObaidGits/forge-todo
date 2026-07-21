/// Native widget behavior: privacy, stale, and locked-placeholder suites.
///
/// Task 11.4 consolidates the container-facing obligations of the mobile
/// widgets (built on the 11.1 bridge and the 11.2 native widgets) that are
/// automatable in-repo. Each case drives a snapshot through the SAME canonical
/// codec the native Android/iOS containers decode (via the in-memory host
/// channel), then asserts what a real container would render:
///
///   * **Privacy end-to-end (R-WIDGET-002, R-WIDGET-004, R-SEC-003):** a
///     snapshot built under app-lock/privacy is redacted and its serialized
///     bytes leak NO item content and NO counts — the number the container
///     could render is zero and none of the hidden titles/subtitles appear in
///     the payload.
///   * **Stale signaling (R-WIDGET-003):** the container can honestly show a
///     "stale" state once a snapshot ages past its threshold, and never wrongly
///     reports a future-stamped snapshot as stale (clock skew).
///   * **Locked placeholder (R-WIDGET-003, R-WIDGET-004):** a locked surface
///     decodes to a redacted, itemless placeholder for every V1 surface, so no
///     sensitive content is shown on a locked home screen.
///
/// Real on-device rendering/placement remains the device follow-up
/// MANUAL-WIDGET-DEVICE-RENDER; these suites lock the contract the device work
/// depends on.
///
/// **Validates: Requirements R-WIDGET-001, R-WIDGET-002, R-WIDGET-003, R-WIDGET-004, R-SEC-003**
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/widgets/application/widget_snapshot_builder.dart';
import 'package:forge/features/widgets/domain/widget_snapshot.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';
import 'package:forge/features/widgets/infrastructure/in_memory_widget_host_channel.dart';

import '../../../helpers/helpers.dart';

EvidenceMetadata _evidence(String suffix, List<String> requirements) =>
    EvidenceMetadata(
      evidenceId: EvidenceId('WIDGET-NATIVE-$suffix'),
      releaseTag: ReleaseTag.v1,
      taskId: SpecTaskId('11.4'),
      requirements: <RequirementId>[
        for (final String requirement in requirements)
          RequirementId(requirement),
      ],
    );

void main() {
  final ProfileId profile = ProfileId('profile-1');

  WidgetSnapshotBuilder builderAt(DateTime utc, {Duration? staleness}) =>
      WidgetSnapshotBuilder(
        clock: FakeClock(initialUtc: utc),
        defaultStaleness: staleness ?? const Duration(minutes: 30),
      );

  List<WidgetSnapshotItem> secretItems(int count) => <WidgetSnapshotItem>[
    for (int i = 0; i < count; i += 1)
      WidgetSnapshotItem(
        id: 'task-$i',
        title: 'CONFIDENTIAL-title-$i',
        subtitle: 'due-secret-$i',
        isComplete: i.isEven,
      ),
  ];

  group('privacy is enforced end-to-end through the container codec', () {
    testWithEvidence(
      _evidence('PRIVACY-NO-LEAK', <String>[
        'R-WIDGET-002',
        'R-WIDGET-004',
        'R-SEC-003',
      ]),
      'a locked snapshot the container decodes carries no content and no counts',
      () async {
        final InMemoryWidgetHostChannel channel = InMemoryWidgetHostChannel();
        final WidgetSnapshotBuilder builder = builderAt(
          DateTime.utc(2024, 6, 1, 12),
        );
        final List<WidgetSnapshotItem> hidden = secretItems(6);
        final WidgetSnapshot locked = builder.build(
          surface: WidgetSurface.todayTasks,
          profileId: profile,
          items: hidden,
          contentVisible: false,
        );
        await channel.publish(locked);

        // What the native container reads back through the shared codec.
        final WidgetSnapshot decoded = channel.read(WidgetSurface.todayTasks)!;
        expect(decoded.redacted, isTrue);
        expect(decoded.items, isEmpty, reason: 'no content survives redaction');

        // The count the container could render is zero — no count leaks.
        final String raw = channel.rawFor(WidgetSurface.todayTasks)!;
        final Map<String, Object?> onWire =
            jsonDecode(raw) as Map<String, Object?>;
        expect((onWire['items']! as List<Object?>), isEmpty);

        // None of the hidden titles/subtitles appear anywhere in the payload.
        for (final WidgetSnapshotItem item in hidden) {
          expect(raw.contains(item.title), isFalse, reason: item.title);
          expect(raw.contains(item.subtitle!), isFalse, reason: item.subtitle);
        }
      },
    );

    testWithEvidence(
      _evidence('PRIVACY-PROP', <String>[
        'R-WIDGET-002',
        'R-WIDGET-004',
        'R-SEC-003',
      ]),
      'across random surfaces and content, a locked publish never leaks a title '
      'or a count to the container',
      () async {
        for (int seed = 0; seed < 300; seed += 1) {
          final Random rng = Random(seed);
          final InMemoryWidgetHostChannel channel = InMemoryWidgetHostChannel();
          final WidgetSnapshotBuilder builder = builderAt(
            DateTime.utc(2024, 1, 1).add(Duration(minutes: seed)),
          );
          final WidgetSurface surface =
              WidgetSurface.values[rng.nextInt(WidgetSurface.values.length)];
          final List<WidgetSnapshotItem> hidden = secretItems(rng.nextInt(12));

          await channel.publish(
            builder.build(
              surface: surface,
              profileId: profile,
              items: hidden,
              contentVisible: false,
            ),
          );

          final String raw = channel.rawFor(surface)!;
          expect(channel.read(surface)!.items, isEmpty, reason: 'seed=$seed');
          for (final WidgetSnapshotItem item in hidden) {
            expect(
              raw.contains(item.title),
              isFalse,
              reason: 'seed=$seed leaked ${item.title}',
            );
          }
        }
      },
    );
  });

  group('stale state is signaled honestly', () {
    testWithEvidence(
      _evidence('STALE-SIGNAL', <String>['R-WIDGET-003']),
      'a container reading an aged snapshot sees a stale freshness state',
      () async {
        final InMemoryWidgetHostChannel channel = InMemoryWidgetHostChannel();
        final WidgetSnapshotBuilder builder = builderAt(
          DateTime.utc(2024, 6, 1, 12),
          staleness: const Duration(minutes: 15),
        );
        final WidgetSnapshot snapshot = builder.build(
          surface: WidgetSurface.studyFocusCountdown,
          profileId: profile,
          items: <WidgetSnapshotItem>[
            WidgetSnapshotItem(
              id: 'focus-1',
              title: 'Deep Work',
              countdownRemainingSeconds: 600,
            ),
          ],
          contentVisible: true,
        );
        await channel.publish(snapshot);

        final WidgetSnapshot decoded = channel.read(
          WidgetSurface.studyFocusCountdown,
        )!;
        final int gen = decoded.generatedAtUtcMicros;
        const int minute = 60 * 1000000;

        // Fresh right after publish and within the threshold.
        expect(decoded.freshnessAt(gen), WidgetFreshness.fresh);
        expect(decoded.freshnessAt(gen + 15 * minute), WidgetFreshness.fresh);
        // Stale once the threshold is exceeded.
        expect(decoded.isStaleAt(gen + 16 * minute), isTrue);
        // Clock skew (a read in the past) is never wrongly reported stale.
        expect(decoded.isStaleAt(gen - minute), isFalse);
      },
    );
  });

  group('locked placeholder covers every surface', () {
    testWithEvidence(
      _evidence('LOCKED-PLACEHOLDER', <String>['R-WIDGET-001', 'R-WIDGET-004']),
      'every V1 surface decodes to a redacted, itemless placeholder when locked',
      () async {
        final InMemoryWidgetHostChannel channel = InMemoryWidgetHostChannel();
        final WidgetSnapshotBuilder builder = builderAt(
          DateTime.utc(2024, 6, 1, 12),
        );
        for (final WidgetSurface surface in WidgetSurface.values) {
          await channel.publish(
            builder.build(
              surface: surface,
              profileId: profile,
              items: secretItems(4),
              contentVisible: false,
            ),
          );
          final WidgetSnapshot decoded = channel.read(surface)!;
          expect(decoded.redacted, isTrue, reason: surface.wireName);
          expect(decoded.items, isEmpty, reason: surface.wireName);
          expect(decoded.surfaceWire, surface.wireName);
        }
      },
    );

    testWithEvidence(
      _evidence('STALE-AND-LOCKED', <String>['R-WIDGET-003', 'R-WIDGET-004']),
      'a locked snapshot that has also aged is both redacted and reported stale',
      () async {
        final InMemoryWidgetHostChannel channel = InMemoryWidgetHostChannel();
        final WidgetSnapshotBuilder builder = builderAt(
          DateTime.utc(2024, 6, 1, 12),
          staleness: const Duration(minutes: 10),
        );
        await channel.publish(
          builder.build(
            surface: WidgetSurface.habitChecklist,
            profileId: profile,
            items: secretItems(3),
            contentVisible: false,
          ),
        );
        final WidgetSnapshot decoded = channel.read(
          WidgetSurface.habitChecklist,
        )!;
        const int minute = 60 * 1000000;
        expect(decoded.redacted, isTrue);
        expect(decoded.items, isEmpty);
        expect(
          decoded.isStaleAt(decoded.generatedAtUtcMicros + 11 * minute),
          isTrue,
        );
      },
    );
  });
}
