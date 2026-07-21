/// Widget deep-link parsing/building tests (R-WIDGET-001, R-WIDGET-003).
///
/// A native widget tap arrives as an untrusted `forge://widget/...` deep link.
/// These tests prove that:
///
///   * a link the native signer builds round-trips back to the same intent and
///     then VERIFIES against the shared signer (native <-> Dart contract);
///   * a tampered link (query mutated after signing) fails verification;
///   * malformed / foreign / unknown-surface / unknown-action links parse to
///     null so the app never trusts them;
///   * "open surface" links parse for every V1 surface (R-WIDGET-001 coverage).
///
/// This is the Dart-side, in-repo coverage of the native contract; on-device
/// rendering and real taps are the manual/platform follow-ups (task 11.4).
///
/// **Validates: Requirements R-WIDGET-001, R-WIDGET-003**
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/widgets/application/widget_intent_verifier.dart';
import 'package:forge/features/widgets/domain/widget_deep_link.dart';
import 'package:forge/features/widgets/domain/widget_intent.dart';
import 'package:forge/features/widgets/domain/widget_platform_contract.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';
import 'package:forge/features/widgets/infrastructure/keyed_hash_widget_intent_signer.dart';

import '../../../helpers/helpers.dart';

EvidenceMetadata _evidence(String suffix, List<String> requirements) =>
    EvidenceMetadata(
      evidenceId: EvidenceId('WIDGET-DEEPLINK-$suffix'),
      releaseTag: ReleaseTag.v1,
      taskId: SpecTaskId('11.2'),
      requirements: <RequirementId>[
        for (final String requirement in requirements)
          RequirementId(requirement),
      ],
    );

const String _secret = 'shared-bridge-secret-value';

/// Builds the same signed action URI a native widget would produce for a tap.
Uri nativeSignedActionUri({
  required KeyedHashWidgetIntentSigner signer,
  required String intentId,
  required String profileId,
  required WidgetIntentAction action,
  required WidgetSurface surface,
  required String target,
  required int issuedAtUtcMicros,
}) {
  final WidgetIntent unsigned = WidgetIntent(
    intentId: intentId,
    profileId: profileId,
    action: action,
    surfaceWire: surface.wireName,
    targetEntityId: target,
    issuedAtUtcMicros: issuedAtUtcMicros,
    token: '',
  );
  final WidgetIntent signed = WidgetIntent(
    intentId: intentId,
    profileId: profileId,
    action: action,
    surfaceWire: surface.wireName,
    targetEntityId: target,
    issuedAtUtcMicros: issuedAtUtcMicros,
    token: signer.sign(unsigned.canonicalPayload()),
  );
  return WidgetDeepLink.buildActionUri(signed);
}

void main() {
  final KeyedHashWidgetIntentSigner signer = KeyedHashWidgetIntentSigner(
    secret: _secret,
  );
  final ProfileId active = ProfileId('profile-1');
  final DateTime nowUtc = DateTime.utc(2024, 6, 1, 12);
  final int nowMicros = nowUtc.microsecondsSinceEpoch;

  WidgetIntentVerifier verifier() => WidgetIntentVerifier(
    signer: signer,
    clock: FakeClock(initialUtc: nowUtc),
    activeProfileId: active,
  );

  group('action links round-trip and verify', () {
    testWithEvidence(
      _evidence('ROUNDTRIP-VERIFY', <String>['R-WIDGET-003']),
      'a native-signed action link parses back to the intent and verifies',
      () {
        final Uri uri = nativeSignedActionUri(
          signer: signer,
          intentId: 'tap-1',
          profileId: active.value,
          action: WidgetIntentAction.completeTask,
          surface: WidgetSurface.todayTasks,
          target: 'task-42',
          issuedAtUtcMicros: nowMicros,
        );

        final WidgetDeepLink? link = WidgetDeepLink.parse(uri);
        expect(link, isA<WidgetActionDeepLink>());
        final WidgetIntent intent = (link! as WidgetActionDeepLink).intent;
        expect(intent.intentId, 'tap-1');
        expect(intent.targetEntityId, 'task-42');
        expect(intent.action, WidgetIntentAction.completeTask);

        final Result<VerifiedWidgetCommand> result = verifier().verify(intent);
        expect(result, isA<Success<VerifiedWidgetCommand>>());
        expect(
          (result as Success<VerifiedWidgetCommand>).value.derivedCommandId,
          'widget-tap-1',
        );
      },
    );

    testWithEvidence(
      _evidence('HABIT-CHECKIN', <String>['R-WIDGET-003']),
      'a habit check-in action link round-trips and verifies',
      () {
        final Uri uri = nativeSignedActionUri(
          signer: signer,
          intentId: 'tap-h',
          profileId: active.value,
          action: WidgetIntentAction.checkInHabit,
          surface: WidgetSurface.habitChecklist,
          target: 'habit-7',
          issuedAtUtcMicros: nowMicros,
        );
        final WidgetDeepLink? link = WidgetDeepLink.parse(uri);
        final WidgetIntent intent = (link! as WidgetActionDeepLink).intent;
        expect(intent.action, WidgetIntentAction.checkInHabit);
        expect(
          verifier().verify(intent),
          isA<Success<VerifiedWidgetCommand>>(),
        );
      },
    );
  });

  group('tampered / malformed links are rejected', () {
    testWithEvidence(
      _evidence('TAMPERED-TARGET', <String>['R-WIDGET-003']),
      'mutating the target after signing parses but fails verification',
      () {
        final Uri signed = nativeSignedActionUri(
          signer: signer,
          intentId: 'tap-1',
          profileId: active.value,
          action: WidgetIntentAction.completeTask,
          surface: WidgetSurface.todayTasks,
          target: 'task-42',
          issuedAtUtcMicros: nowMicros,
        );
        final Map<String, String> tampered = Map<String, String>.of(
          signed.queryParameters,
        )..[WidgetPlatformContract.paramTarget] = 'task-999';
        final Uri attack = signed.replace(queryParameters: tampered);

        final WidgetDeepLink? link = WidgetDeepLink.parse(attack);
        final WidgetIntent intent = (link! as WidgetActionDeepLink).intent;
        final Result<VerifiedWidgetCommand> result = verifier().verify(intent);
        expect(result, isA<Failed<VerifiedWidgetCommand>>());
        expect(
          (result as Failed<VerifiedWidgetCommand>).failure.code,
          'widget.intent_rejected.invalidSignature',
        );
      },
    );

    testWithEvidence(
      _evidence('BAD-SCHEME', <String>['R-WIDGET-003']),
      'a foreign scheme or host does not parse',
      () {
        expect(
          WidgetDeepLink.parse(Uri.parse('https://widget/intent?x=1')),
          isNull,
        );
        expect(
          WidgetDeepLink.parse(Uri.parse('forge://notes/intent?x=1')),
          isNull,
        );
      },
    );

    testWithEvidence(
      _evidence('MISSING-FIELDS', <String>['R-WIDGET-003']),
      'an action link missing required fields does not parse',
      () {
        final Uri incomplete = Uri(
          scheme: WidgetPlatformContract.deepLinkScheme,
          host: WidgetPlatformContract.deepLinkHost,
          pathSegments: <String>[WidgetPlatformContract.deepLinkActionPath],
          queryParameters: <String, String>{
            WidgetPlatformContract.paramAction: 'complete_task',
            WidgetPlatformContract.paramIntentId: 'tap-1',
            // profile, target, token, issued_at omitted
          },
        );
        expect(WidgetDeepLink.parse(incomplete), isNull);
      },
    );

    testWithEvidence(
      _evidence('UNKNOWN-ACTION', <String>['R-WIDGET-003']),
      'an unknown action name does not parse',
      () {
        final Uri uri = Uri(
          scheme: WidgetPlatformContract.deepLinkScheme,
          host: WidgetPlatformContract.deepLinkHost,
          pathSegments: <String>[WidgetPlatformContract.deepLinkActionPath],
          queryParameters: <String, String>{
            WidgetPlatformContract.paramAction: 'delete_everything',
            WidgetPlatformContract.paramIntentId: 'tap-1',
            WidgetPlatformContract.paramProfileId: 'profile-1',
            WidgetPlatformContract.paramSurface: 'today_tasks',
            WidgetPlatformContract.paramTarget: 'task-1',
            WidgetPlatformContract.paramToken: 'ff',
            WidgetPlatformContract.paramIssuedAt: '$nowMicros',
          },
        );
        expect(WidgetDeepLink.parse(uri), isNull);
      },
    );

    testWithEvidence(
      _evidence('NON-INT-TIMESTAMP', <String>['R-WIDGET-003']),
      'a non-integer timestamp does not parse',
      () {
        final Uri uri = Uri(
          scheme: WidgetPlatformContract.deepLinkScheme,
          host: WidgetPlatformContract.deepLinkHost,
          pathSegments: <String>[WidgetPlatformContract.deepLinkActionPath],
          queryParameters: <String, String>{
            WidgetPlatformContract.paramAction: 'complete_task',
            WidgetPlatformContract.paramIntentId: 'tap-1',
            WidgetPlatformContract.paramProfileId: 'profile-1',
            WidgetPlatformContract.paramSurface: 'today_tasks',
            WidgetPlatformContract.paramTarget: 'task-1',
            WidgetPlatformContract.paramToken: 'ff',
            WidgetPlatformContract.paramIssuedAt: 'not-a-number',
          },
        );
        expect(WidgetDeepLink.parse(uri), isNull);
      },
    );
  });

  group('open links cover every V1 surface', () {
    testWithEvidence(
      _evidence('OPEN-ALL-SURFACES', <String>['R-WIDGET-001']),
      'every widget surface has a build/parse open round-trip',
      () {
        for (final WidgetSurface surface in WidgetSurface.values) {
          final Uri uri = WidgetDeepLink.buildOpenUri(surface);
          final WidgetDeepLink? link = WidgetDeepLink.parse(uri);
          expect(link, isA<WidgetOpenDeepLink>(), reason: surface.wireName);
          expect((link! as WidgetOpenDeepLink).surface, surface);
        }
      },
    );

    testWithEvidence(
      _evidence('OPEN-UNKNOWN-SURFACE', <String>['R-WIDGET-001']),
      'an unknown surface on an open link does not parse',
      () {
        final Uri uri = Uri(
          scheme: WidgetPlatformContract.deepLinkScheme,
          host: WidgetPlatformContract.deepLinkHost,
          pathSegments: <String>[WidgetPlatformContract.deepLinkOpenPath],
          queryParameters: <String, String>{
            WidgetPlatformContract.paramSurface: 'crystal_ball',
          },
        );
        expect(WidgetDeepLink.parse(uri), isNull);
      },
    );
  });
}
