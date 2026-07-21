/// Redirect-flow primitives: exact redirect allowlist, anti-forgery state/nonce
/// generation, callback parsing, and the one-use callback guard (R-SYNC-001;
/// design.md §13; data-model.md §6 "one-use callback receipts").
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/auth/oauth_flow.dart';

import '../../helpers/evidence.dart';
import '../../helpers/fake_auth_ports.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-AUTH-FLOW-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.4'),
  requirements: <RequirementId>[RequirementId('R-SYNC-001')],
);

void main() {
  group('RedirectUriAllowlist exact matching', () {
    final RedirectUriAllowlist allowlist = RedirectUriAllowlist(<String>[
      'forge://auth/callback',
      'https://app.forge.example/callback',
    ]);

    testWithEvidence(
      _evidence('EXACT-MATCH-ALLOWED'),
      'a registered redirect matches exactly',
      () {
        expect(allowlist.isAllowed('forge://auth/callback'), isTrue);
        expect(
          allowlist.isAllowed('https://app.forge.example/callback'),
          isTrue,
        );
      },
    );

    testWithEvidence(
      _evidence('SCHEME-HOST-CASE-CANONICAL'),
      'scheme and host case are canonicalized before matching',
      () {
        expect(
          allowlist.isAllowed('HTTPS://App.Forge.Example/callback'),
          isTrue,
        );
      },
    );

    testWithEvidence(
      _evidence('REJECT-PREFIX-AND-EXTRA'),
      'prefix, subpath, extra query, or fragment are not exact matches',
      () {
        expect(
          allowlist.isAllowed('https://app.forge.example/callback/evil'),
          isFalse,
        );
        expect(
          allowlist.isAllowed('https://app.forge.example/callback?x=1'),
          isFalse,
        );
        expect(allowlist.isAllowed('https://evil.example/callback'), isFalse);
        expect(allowlist.isAllowed('forge://auth/callback#frag'), isFalse);
      },
    );
  });

  group('AntiForgeryFactory', () {
    testWithEvidence(
      _evidence('STATE-NONCE-DISTINCT'),
      'successive state and nonce values are distinct high-entropy secrets',
      () {
        final AntiForgeryFactory factory = AntiForgeryFactory(
          FakeSecureRandomSource(),
        );
        final OAuthState s1 = factory.createState();
        final OAuthState s2 = factory.createState();
        final OAuthNonce n1 = factory.createNonce();
        expect(s1.value.reveal(), isNot(s2.value.reveal()));
        expect(s1.value.reveal(), isNot(n1.value.reveal()));
        // Secrets never leak through toString.
        expect(s1.toString(), 'OAuthState(<redacted>)');
        expect(s1.value.toString(), '[redacted]');
      },
    );
  });

  group('AuthCallback.parse', () {
    testWithEvidence(
      _evidence('PARSE-CODE-STATE'),
      'parses code and state and strips query from the redirect target',
      () {
        final AuthCallback callback = AuthCallback.parse(
          'forge://auth/callback?code=abc123&state=xyz',
        );
        expect(callback.redirectUri, 'forge://auth/callback');
        expect(callback.state, 'xyz');
        expect(callback.code!.reveal(), 'abc123');
        expect(callback.hasError, isFalse);
      },
    );

    testWithEvidence(
      _evidence('PARSE-ERROR-PARAM'),
      'surfaces a provider error parameter',
      () {
        final AuthCallback callback = AuthCallback.parse(
          'forge://auth/callback?error=access_denied&state=xyz',
        );
        expect(callback.hasError, isTrue);
        expect(callback.code, isNull);
      },
    );
  });

  group('OneUseCallbackGuard', () {
    testWithEvidence(
      _evidence('CONSUME-ONCE-THEN-REPLAY-REJECTED'),
      'a receipt consumes exactly once; every replay is rejected',
      () {
        final OneUseCallbackGuard guard = OneUseCallbackGuard();
        expect(guard.consume('req-1'), isTrue);
        expect(guard.isConsumed('req-1'), isTrue);
        expect(guard.consume('req-1'), isFalse);
        expect(guard.consume('req-1'), isFalse);
        // Still consumed (idempotent effect).
        expect(guard.isConsumed('req-1'), isTrue);
      },
    );

    testWithEvidence(
      _evidence('PROP-EXACTLY-ONE-SUCCESS-PER-RECEIPT'),
      'over random interleavings each receipt yields exactly one consume=true',
      () {
        for (int seed = 0; seed < 300; seed += 1) {
          final Random rng = Random(seed);
          final OneUseCallbackGuard guard = OneUseCallbackGuard();
          final int receiptCount = 1 + rng.nextInt(5);
          final Map<String, int> successes = <String, int>{};
          final int operations = 5 + rng.nextInt(30);
          for (int i = 0; i < operations; i += 1) {
            final String id = 'req-${rng.nextInt(receiptCount)}';
            final bool consumed = guard.consume(id);
            if (consumed) {
              successes.update(id, (int v) => v + 1, ifAbsent: () => 1);
            }
            // Once consumed, isConsumed must stay true.
            expect(guard.isConsumed(id), isTrue);
          }
          // Every receipt that was ever consumed succeeded exactly once.
          for (final int count in successes.values) {
            expect(count, 1, reason: 'double consume for seed=$seed');
          }
        }
      },
    );
  });
}
