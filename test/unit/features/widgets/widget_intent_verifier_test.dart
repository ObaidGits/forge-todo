/// Widget intent spoof-resistance tests (R-WIDGET-003).
///
/// A widget-originated intent is untrusted. These tests prove the verifier
/// rejects a forged signature, a tampered payload, a cross-profile intent, and
/// a stale/replayed or future-dated intent, while accepting a well-formed,
/// freshly signed intent bound to the active profile.
///
/// **Validates: Requirements R-WIDGET-003**
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/widgets/application/widget_intent_verifier.dart';
import 'package:forge/features/widgets/domain/widget_intent.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';
import 'package:forge/features/widgets/infrastructure/keyed_hash_widget_intent_signer.dart';

import '../../../helpers/helpers.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('WIDGET-INTENT-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('11.1'),
  requirements: <RequirementId>[RequirementId('R-WIDGET-003')],
);

const String _secret = 'shared-bridge-secret-value';

WidgetIntent _signedIntent({
  required KeyedHashWidgetIntentSigner signer,
  String intentId = 'tap-1',
  String profileId = 'profile-1',
  WidgetIntentAction action = WidgetIntentAction.completeTask,
  WidgetSurface surface = WidgetSurface.todayTasks,
  String targetEntityId = 'task-42',
  required int issuedAtUtcMicros,
  String? tokenOverride,
}) {
  final WidgetIntent unsigned = WidgetIntent(
    intentId: intentId,
    profileId: profileId,
    action: action,
    surfaceWire: surface.wireName,
    targetEntityId: targetEntityId,
    issuedAtUtcMicros: issuedAtUtcMicros,
    token: '',
  );
  return WidgetIntent(
    intentId: intentId,
    profileId: profileId,
    action: action,
    surfaceWire: surface.wireName,
    targetEntityId: targetEntityId,
    issuedAtUtcMicros: issuedAtUtcMicros,
    token: tokenOverride ?? signer.sign(unsigned.canonicalPayload()),
  );
}

void main() {
  final ProfileId active = ProfileId('profile-1');
  final KeyedHashWidgetIntentSigner signer = KeyedHashWidgetIntentSigner(
    secret: _secret,
  );
  final DateTime nowUtc = DateTime.utc(2024, 6, 1, 12);
  final int nowMicros = nowUtc.microsecondsSinceEpoch;

  WidgetIntentVerifier verifier() => WidgetIntentVerifier(
    signer: signer,
    clock: FakeClock(initialUtc: nowUtc),
    activeProfileId: active,
  );

  String rejectionCode(Result<VerifiedWidgetCommand> result) =>
      (result as Failed<VerifiedWidgetCommand>).failure.code;

  group('accepts a valid intent', () {
    testWithEvidence(
      _evidence('ACCEPT-VALID'),
      'a fresh, correctly signed, same-profile intent verifies to a command',
      () {
        final WidgetIntent intent = _signedIntent(
          signer: signer,
          issuedAtUtcMicros: nowMicros,
        );
        final Result<VerifiedWidgetCommand> result = verifier().verify(intent);
        expect(result, isA<Success<VerifiedWidgetCommand>>());
        final VerifiedWidgetCommand command =
            (result as Success<VerifiedWidgetCommand>).value;
        expect(command.derivedCommandId, 'widget-tap-1');
        expect(command.targetEntityId, 'task-42');
      },
    );
  });

  group('rejects spoofed intents', () {
    testWithEvidence(
      _evidence('REJECT-FORGED-SIG'),
      'a wrong token is rejected as an invalid signature',
      () {
        final WidgetIntent intent = _signedIntent(
          signer: signer,
          issuedAtUtcMicros: nowMicros,
          tokenOverride: 'deadbeef' * 8,
        );
        final Result<VerifiedWidgetCommand> result = verifier().verify(intent);
        expect(
          rejectionCode(result),
          'widget.intent_rejected.invalidSignature',
        );
      },
    );

    testWithEvidence(
      _evidence('REJECT-TAMPERED'),
      'a token valid for one target does not authenticate a different target',
      () {
        final WidgetIntent original = _signedIntent(
          signer: signer,
          issuedAtUtcMicros: nowMicros,
          targetEntityId: 'task-42',
        );
        // Reuse the token but swap the target — the canonical payload changes.
        final WidgetIntent tampered = WidgetIntent(
          intentId: original.intentId,
          profileId: original.profileId,
          action: original.action,
          surfaceWire: original.surfaceWire,
          targetEntityId: 'task-999',
          issuedAtUtcMicros: original.issuedAtUtcMicros,
          token: original.token,
        );
        final Result<VerifiedWidgetCommand> result = verifier().verify(
          tampered,
        );
        expect(
          rejectionCode(result),
          'widget.intent_rejected.invalidSignature',
        );
      },
    );

    testWithEvidence(
      _evidence('REJECT-CROSS-PROFILE'),
      'a correctly signed intent for another profile is rejected',
      () {
        final WidgetIntent intent = _signedIntent(
          signer: signer,
          profileId: 'profile-2',
          issuedAtUtcMicros: nowMicros,
        );
        final Result<VerifiedWidgetCommand> result = verifier().verify(intent);
        expect(rejectionCode(result), 'widget.intent_rejected.profileMismatch');
      },
    );

    testWithEvidence(
      _evidence('REJECT-EXPIRED'),
      'an intent older than the freshness window is rejected (replay guard)',
      () {
        final WidgetIntent intent = _signedIntent(
          signer: signer,
          issuedAtUtcMicros:
              nowMicros - const Duration(minutes: 10).inMicroseconds,
        );
        final Result<VerifiedWidgetCommand> result = verifier().verify(intent);
        expect(rejectionCode(result), 'widget.intent_rejected.expired');
      },
    );

    testWithEvidence(
      _evidence('REJECT-FUTURE'),
      'an intent dated far in the future is rejected',
      () {
        final WidgetIntent intent = _signedIntent(
          signer: signer,
          issuedAtUtcMicros:
              nowMicros + const Duration(minutes: 5).inMicroseconds,
        );
        final Result<VerifiedWidgetCommand> result = verifier().verify(intent);
        expect(rejectionCode(result), 'widget.intent_rejected.future');
      },
    );

    testWithEvidence(
      _evidence('REJECT-MALFORMED'),
      'an intent with an empty target is rejected as malformed',
      () {
        final WidgetIntent intent = _signedIntent(
          signer: signer,
          targetEntityId: '',
          issuedAtUtcMicros: nowMicros,
        );
        final Result<VerifiedWidgetCommand> result = verifier().verify(intent);
        expect(rejectionCode(result), 'widget.intent_rejected.malformed');
      },
    );
  });

  group(
    'property: only correctly signed, fresh, same-profile intents verify',
    () {
      testWithEvidence(
        _evidence('PROP-SPOOF'),
        'across randomized forgeries and tampering, only a faithful intent is '
        'accepted and its command id is deterministic',
        () {
          final KeyedHashWidgetIntentSigner attacker =
              KeyedHashWidgetIntentSigner(secret: 'attacker-secret-guess!!');
          for (int seed = 0; seed < 500; seed += 1) {
            final Random rng = Random(seed);
            final int ageSeconds = rng.nextInt(600) - 30; // -30..569s
            final int issued = nowMicros - ageSeconds * 1000000;
            final String profileId = rng.nextBool() ? 'profile-1' : 'profile-2';
            final String target = 'task-${rng.nextInt(1000)}';
            final WidgetIntentAction action = WidgetIntentAction
                .values[rng.nextInt(WidgetIntentAction.values.length)];

            // Choose how the token is produced.
            final int mode = rng.nextInt(4);
            final WidgetIntent base = WidgetIntent(
              intentId: 'tap-$seed',
              profileId: profileId,
              action: action,
              surfaceWire: WidgetSurface.todayTasks.wireName,
              targetEntityId: target,
              issuedAtUtcMicros: issued,
              token: '',
            );
            final String token = switch (mode) {
              0 => signer.sign(base.canonicalPayload()), // faithful
              1 => attacker.sign(base.canonicalPayload()), // forged key
              2 => signer.sign('$profileId:$target:tampered'), // wrong payload
              _ => 'ff' * 32, // garbage
            };
            final WidgetIntent intent = WidgetIntent(
              intentId: base.intentId,
              profileId: profileId,
              action: action,
              surfaceWire: base.surfaceWire,
              targetEntityId: target,
              issuedAtUtcMicros: issued,
              token: token,
            );

            final Result<VerifiedWidgetCommand> result = verifier().verify(
              intent,
            );

            final bool freshlySigned = mode == 0;
            final bool sameProfile = profileId == 'profile-1';
            final bool fresh = ageSeconds >= -30 && ageSeconds <= 300;
            final bool shouldAccept = freshlySigned && sameProfile && fresh;

            if (shouldAccept) {
              expect(
                result,
                isA<Success<VerifiedWidgetCommand>>(),
                reason: 'seed=$seed should accept',
              );
              expect(
                (result as Success<VerifiedWidgetCommand>)
                    .value
                    .derivedCommandId,
                'widget-tap-$seed',
              );
            } else {
              expect(
                result,
                isA<Failed<VerifiedWidgetCommand>>(),
                reason:
                    'seed=$seed mode=$mode profile=$profileId age=$ageSeconds '
                    'must be rejected',
              );
            }
          }
        },
      );
    },
  );

  group('keyed signer', () {
    testWithEvidence(
      _evidence('SIGNER-TAMPER'),
      'any change to the payload changes the tag and fails verification',
      () {
        for (int seed = 0; seed < 300; seed += 1) {
          final Random rng = Random(seed);
          final String payload = 'payload-${rng.nextInt(1 << 20)}';
          final String tag = signer.sign(payload);
          expect(signer.verify(payload, tag), isTrue);
          expect(signer.verify('$payload ', tag), isFalse);
          // A signer with a different secret cannot reproduce the tag.
          final KeyedHashWidgetIntentSigner other = KeyedHashWidgetIntentSigner(
            secret: 'another-secret-$seed-pad',
          );
          expect(other.sign(payload) == tag, isFalse);
        }
      },
    );
  });
}
