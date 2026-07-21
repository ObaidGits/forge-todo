import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/routing/uri_policy.dart';

/// Generative (fuzz) property tests for the centralized [UriPolicy].
///
/// The example suite ([uri_policy_test.dart]) pins specific accept/reject
/// cases; this suite proves the policy's structural guarantees across a large
/// space of randomly assembled inbound/outbound URIs mixing safe opaque-ID
/// routes with adversarial schemes, hosts, traversal, content-like segments,
/// duplicate/opaque queries, fragments, credentials and oversized components.
///
/// Invariants for every generated input:
///   1. Evaluation never throws.
///   2. Deny-by-default: an accepted inbound decision must resolve to a
///      route location that the policy itself re-validates, that starts with
///      `/`, and that carries no query, fragment, whitespace or raw content.
///   3. No content leak: a rejected decision exposes neither a canonical URI
///      nor a route location (the rejected input is never echoed back).
///   4. Outbound links are denied unless HTTPS + an explicitly allowlisted
///      host + user-initiated + no query/fragment/credentials/port.
///
/// **Validates: Requirements R-SEC-005, R-PLAN-001**
void main() {
  const String uuid = '01890f3e-7b8a-7cc2-8b34-123456789abc';

  const List<String> schemes = <String>[
    'forge',
    'http',
    'https',
    'javascript',
    'file',
    'data',
    'vbscript',
    'ftp',
    'FORGE',
    'forge ',
  ];
  const List<String> hosts = <String>[
    'app',
    'App',
    'evil.example.com',
    'docs.example.com',
    'localhost',
    '',
    'app:8080',
  ];
  final List<String> paths = <String>[
    '/tasks/$uuid',
    '/notes/$uuid',
    '/planner/$uuid',
    '/today',
    '/settings/privacy',
    '/notes/private-note-title',
    '/tasks/../secret',
    '/search',
    '/goals/$uuid/roadmap',
    '/learn/$uuid/item/$uuid',
    '/%74oday',
    '/tasks/$uuid/extra/segment',
    '/notes/${'a' * 300}',
    '//evil',
    '/',
    '',
  ];
  const List<String> queries = <String>[
    '',
    '?item=one&item=two',
    '?query=private',
    '#frag',
    '?a=b#c',
  ];

  String randomInbound(Random random) {
    final String scheme = schemes[random.nextInt(schemes.length)];
    final String host = hosts[random.nextInt(hosts.length)];
    final String path = paths[random.nextInt(paths.length)];
    final String query = queries[random.nextInt(queries.length)];
    return '$scheme://$host$path$query';
  }

  test(
    '[TEST-URI-FUZZ-INBOUND][MVP][TASK-5.6][R-SEC-005] '
    'random inbound URIs never throw, never leak, and accepts are canonical',
    () {
      final UriPolicy policy = UriPolicy();
      for (final int seed in <int>[1, 7, 42, 1337, 99999]) {
        final Random random = Random(seed);
        for (int i = 0; i < 500; i += 1) {
          final String raw = randomInbound(random);

          late final UriPolicyDecision decision;
          expect(
            () => decision = policy.evaluateInbound(raw),
            returnsNormally,
            reason: 'evaluateInbound threw for: $raw',
          );

          if (decision.allowed) {
            // (2) An accepted route must be a clean, re-validatable location.
            final String? location = decision.routeLocation;
            expect(location, isNotNull, reason: 'accepted but no route: $raw');
            expect(location!.startsWith('/'), isTrue);
            expect(location, isNot(contains('?')));
            expect(location, isNot(contains('#')));
            expect(location, isNot(contains(' ')));
            expect(location, isNot(contains('..')));
            expect(
              policy.validateRouteLocation(location),
              isNull,
              reason: 're-validation rejected an accepted route: $location',
            );
          } else {
            // (3) A rejection never carries the input forward.
            expect(decision.canonicalUri, isNull);
            expect(decision.routeLocation, isNull);
            expect(decision.rejection, isNotNull);
          }
        }
      }
    },
  );

  test('[TEST-URI-FUZZ-DENY-DEFAULT][MVP][TASK-5.6][R-SEC-005] '
      'inbound content-like identifiers are always rejected without echo', () {
    final UriPolicy policy = UriPolicy();
    final Random random = Random(2024);
    const List<String> contentWords = <String>[
      'my-private-note',
      'quarterly-plan',
      'passwords',
      'secret title',
      'search?q=confidential',
    ];
    for (int i = 0; i < 200; i += 1) {
      final String word = contentWords[random.nextInt(contentWords.length)];
      final String type = <String>[
        'notes',
        'tasks',
        'goals',
      ][random.nextInt(3)];
      final UriPolicyDecision decision = policy.evaluateInbound(
        'forge://app/$type/$word',
      );
      expect(decision.allowed, isFalse);
      expect(decision.canonicalUri, isNull);
      expect(decision.routeLocation, isNull);
    }
  });

  test(
    '[TEST-URI-FUZZ-OUTBOUND][MVP][TASK-5.6][R-SEC-005] '
    'outbound links are deny-by-default and require HTTPS + allowlist + action',
    () {
      final UriPolicy policy = UriPolicy(
        externalHosts: const <String>{'docs.example.com'},
      );
      final Random random = Random(4242);
      const List<String> outbound = <String>[
        'https://docs.example.com/guide',
        'https://docs.example.com/guide?query=private',
        'https://docs.example.com/guide#frag',
        'https://user@docs.example.com/guide',
        'https://docs.example.com:8443/guide',
        'http://docs.example.com/guide',
        'https://evil.example.com/guide',
        'ftp://docs.example.com/guide',
      ];
      for (int i = 0; i < 400; i += 1) {
        final String raw = outbound[random.nextInt(outbound.length)];
        final bool userInitiated = random.nextBool();
        late final UriPolicyDecision decision;
        expect(
          () => decision = policy.evaluateOutbound(
            Uri.parse(raw),
            userInitiated: userInitiated,
          ),
          returnsNormally,
        );

        final bool isCleanApprovedHost =
            raw == 'https://docs.example.com/guide';
        if (decision.allowed) {
          // Only the single clean, allowlisted, user-initiated URL may pass.
          expect(isCleanApprovedHost, isTrue, reason: 'unexpected allow: $raw');
          expect(userInitiated, isTrue);
          expect(decision.requiresExplicitAction, isTrue);
        } else {
          expect(decision.rejection, isNotNull);
        }
      }
    },
  );

  test('[TEST-URI-FUZZ-EMPTY-ALLOWLIST][MVP][TASK-5.6][R-SEC-005] '
      'with no allowlisted hosts every outbound link is denied', () {
    final UriPolicy policy = UriPolicy();
    final Random random = Random(7);
    const List<String> anyHttps = <String>[
      'https://example.com',
      'https://docs.example.com/x',
      'https://a.b.c/d',
    ];
    for (int i = 0; i < 100; i += 1) {
      final Uri uri = Uri.parse(anyHttps[random.nextInt(anyHttps.length)]);
      expect(
        policy.evaluateOutbound(uri, userInitiated: true).allowed,
        isFalse,
      );
    }
  });
}
