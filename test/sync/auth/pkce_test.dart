/// PKCE (RFC 7636) code verifier/challenge generation and verification for the
/// Supabase redirect flow (R-SYNC-001; design.md §13).
///
/// Unit anchors plus a generative property: for any generated S256 pair the
/// verifier verifies against its challenge, and any tampered challenge or
/// mismatched verifier fails. Uses the real SHA-256 so the S256 relationship is
/// exercised end to end.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/auth/pkce.dart';

import '../../helpers/evidence.dart';
import '../../helpers/fake_auth_ports.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-AUTH-PKCE-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.4'),
  requirements: <RequirementId>[RequirementId('R-SYNC-001')],
);

PkceFactory _factory({int seed = 1}) => PkceFactory(
  random: FakeSecureRandomSource(seed: seed),
  hasher: const RealSha256Hasher(),
);

void main() {
  group('PkceFactory S256', () {
    testWithEvidence(
      _evidence('RFC7636-VECTOR'),
      'derives the RFC 7636 Appendix B challenge from the sample verifier',
      () {
        // RFC 7636 Appendix B worked example.
        final CodeVerifier verifier = CodeVerifier(
          'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
        );
        final CodeChallenge challenge = _factory().challengeFor(verifier);
        expect(challenge.value, 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
        expect(challenge.method, PkceChallengeMethod.s256);
      },
    );

    testWithEvidence(
      _evidence('GENERATED-VERIFIER-GRAMMAR'),
      'a generated verifier is 43 chars of the unreserved grammar with no pad',
      () {
        final PkcePair pair = _factory().createS256();
        expect(pair.verifier.value.length, 43);
        expect(
          RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(pair.verifier.value),
          isTrue,
        );
        expect(pair.challenge.value.contains('='), isFalse);
      },
    );

    testWithEvidence(
      _evidence('VERIFY-ROUNDTRIP'),
      'a freshly created pair verifies true',
      () {
        final PkcePair pair = _factory().createS256();
        expect(_factory().verify(pair.verifier, pair.challenge), isTrue);
      },
    );

    testWithEvidence(
      _evidence('PLAIN-METHOD'),
      'plain method verifies verifier equal to challenge',
      () {
        const CodeChallenge plain = CodeChallenge(
          'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
          PkceChallengeMethod.plain,
        );
        final CodeVerifier verifier = CodeVerifier(
          'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
        );
        expect(_factory().verify(verifier, plain), isTrue);
      },
    );

    testWithEvidence(
      _evidence('REJECT-SHORT-VERIFIER'),
      'a verifier shorter than 43 chars is rejected by the grammar',
      () {
        expect(() => CodeVerifier('too-short'), throwsArgumentError);
      },
    );
  });

  group('PkceFactory properties', () {
    testWithEvidence(
      _evidence('PROP-VERIFY-TRUE-AND-TAMPER-FALSE'),
      'every generated pair verifies, and any single-char tamper fails',
      () {
        for (int seed = 1; seed <= 500; seed += 1) {
          final PkceFactory factory = _factory(seed: seed);
          final PkcePair pair = factory.createS256();

          // Correct pair always verifies.
          expect(
            factory.verify(pair.verifier, pair.challenge),
            isTrue,
            reason: 'valid pair failed for seed=$seed',
          );

          // Tamper one character of the challenge — must fail.
          final String value = pair.challenge.value;
          final int i = seed % value.length;
          final String swapped = value[i] == 'A' ? 'B' : 'A';
          final String tampered = value.replaceRange(i, i + 1, swapped);
          if (tampered != value) {
            expect(
              factory.verify(
                pair.verifier,
                CodeChallenge(tampered, PkceChallengeMethod.s256),
              ),
              isFalse,
              reason: 'tampered challenge verified for seed=$seed',
            );
          }

          // A different verifier must not match this challenge.
          final PkcePair other = _factory(seed: seed + 100000).createS256();
          expect(
            factory.verify(other.verifier, pair.challenge),
            isFalse,
            reason: 'mismatched verifier verified for seed=$seed',
          );
        }
      },
    );
  });
}
