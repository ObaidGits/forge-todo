/// Independent security conformance harness — URI policy (task 12.4).
///
/// Verifies the centralized [UriPolicy] boundary: inbound links are
/// deny-by-default (only opaque `forge://app` routes, no content/query),
/// outbound links require HTTPS + an allowlisted host + explicit user action
/// and never carry content, and no rejection ever echoes the offending input.
///
/// **Validates: Requirements R-SEC-005, NFR-SEC-001**
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/routing/uri_policy.dart';

import '../helpers/evidence.dart';
import 'security_conformance_support.dart';

void main() {
  const String opaqueId = '01890f3e-7b8a-7cc2-8b34-123456789abc';

  group('Inbound deny-by-default', () {
    final UriPolicy policy = UriPolicy();

    testWithEvidence(
      secEvidence('URI-INBOUND-ALLOW-OPAQUE', <String>['R-SEC-005']),
      'only opaque forge://app routes are admitted',
      () {
        final UriPolicyDecision decision = policy.evaluateInbound(
          'forge://app/tasks/$opaqueId',
        );
        expect(decision.allowed, isTrue);
        expect(decision.routeLocation, '/tasks/$opaqueId');
      },
    );

    testWithEvidence(
      secEvidence('URI-INBOUND-DENY-FOREIGN', <String>['R-SEC-005']),
      'foreign schemes/hosts, content queries, and traversal are all rejected',
      () {
        for (final String raw in <String>[
          'https://evil.test/steal',
          'forge://evil/tasks/$opaqueId',
          'javascript:alert(1)',
          'forge://app/tasks/$opaqueId?q=secret+search+text',
          'forge://app/notes/../secrets',
          'forge://app/search/note%20title',
        ]) {
          final UriPolicyDecision decision = policy.evaluateInbound(raw);
          expect(decision.allowed, isFalse, reason: raw);
          expect(decision.rejection, isNotNull);
        }
      },
    );

    testWithEvidence(
      secEvidence('URI-INBOUND-NO-ECHO', <String>['R-SEC-005']),
      'a rejection never surfaces the offending input value',
      () {
        const String secret = 'forge://app/notes/SECRET-NOTE-TITLE';
        final UriPolicyDecision decision = policy.evaluateInbound(secret);
        expect(decision.allowed, isFalse);
        expect(decision.canonicalUri, isNull);
        // The decision only carries a stable enum, never the raw input.
        expect(decision.rejection, isA<UriRejection>());
      },
    );
  });

  group('Outbound HTTPS + allowlist + explicit action', () {
    testWithEvidence(
      secEvidence('URI-OUTBOUND-ALLOWLIST', <String>['R-SEC-005']),
      'a user-initiated HTTPS link to an allowlisted host is admitted',
      () {
        final UriPolicy policy = UriPolicy(
          externalHosts: const <String>{'docs.forge.test'},
        );
        final UriPolicyDecision decision = policy.evaluateOutbound(
          Uri.parse('https://docs.forge.test/help'),
          userInitiated: true,
        );
        expect(decision.allowed, isTrue);
        expect(decision.requiresExplicitAction, isTrue);
      },
    );

    testWithEvidence(
      secEvidence('URI-OUTBOUND-DENY-DEFAULT', <String>['R-SEC-005']),
      'non-HTTPS, non-allowlisted, un-initiated, and content-bearing links '
      'are all denied',
      () {
        final UriPolicy policy = UriPolicy(
          externalHosts: const <String>{'docs.forge.test'},
        );
        // Non-HTTPS.
        expect(
          policy
              .evaluateOutbound(
                Uri.parse('http://docs.forge.test/x'),
                userInitiated: true,
              )
              .allowed,
          isFalse,
        );
        // Host not on the allowlist.
        expect(
          policy
              .evaluateOutbound(
                Uri.parse('https://evil.test/x'),
                userInitiated: true,
              )
              .allowed,
          isFalse,
        );
        // Not user-initiated.
        expect(
          policy
              .evaluateOutbound(
                Uri.parse('https://docs.forge.test/x'),
                userInitiated: false,
              )
              .allowed,
          isFalse,
        );
        // Carries content/search text in the query.
        expect(
          policy
              .evaluateOutbound(
                Uri.parse('https://docs.forge.test/x?q=my+note'),
                userInitiated: true,
              )
              .allowed,
          isFalse,
        );
      },
    );

    testWithEvidence(
      secEvidence('URI-OUTBOUND-EMPTY-ALLOWLIST', <String>['R-SEC-005']),
      'with no allowlisted hosts every outbound link is denied',
      () {
        final UriPolicy policy = UriPolicy();
        expect(
          policy
              .evaluateOutbound(
                Uri.parse('https://docs.forge.test/help'),
                userInitiated: true,
              )
              .allowed,
          isFalse,
        );
      },
    );
  });
}
