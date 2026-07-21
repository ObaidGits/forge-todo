import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/routing/uri_policy.dart';

void main() {
  const String taskId = '01890f3e-7b8a-7cc2-8b34-123456789abc';

  group('UriPolicy inbound links', () {
    final UriPolicy policy = UriPolicy();

    test('accepts an exact allowlisted route with only an opaque UUIDv7', () {
      final UriPolicyDecision decision = policy.evaluateInbound(
        'forge://app/tasks/$taskId',
      );

      expect(decision.allowed, isTrue);
      expect(decision.routeLocation, '/tasks/$taskId');
    });

    test(
      'rejects content-like identifiers and never returns rejected input',
      () {
        final UriPolicyDecision decision = policy.evaluateInbound(
          'forge://app/notes/private-note-title',
        );

        expect(decision.allowed, isFalse);
        expect(decision.rejection, UriRejection.invalidIdentifier);
        expect(decision.canonicalUri, isNull);
        expect(decision.routeLocation, isNull);
      },
    );

    test('rejects duplicate or unexpected query parameters', () {
      final UriPolicyDecision duplicate = policy.evaluateInbound(
        'forge://app/today?item=one&item=two',
      );
      final UriPolicyDecision content = policy.evaluateInbound(
        'forge://app/search?query=private',
      );

      expect(duplicate.rejection, UriRejection.duplicateParameter);
      expect(content.rejection, UriRejection.unexpectedParameter);
    });

    test('rejects non-canonical percent encoding', () {
      final UriPolicyDecision decision = policy.evaluateInbound(
        'forge://app/%74oday',
      );

      expect(decision.rejection, UriRejection.nonCanonical);
    });

    test('rejects unknown desktop arguments and file paths', () {
      expect(
        policy.evaluateDesktopArguments(<String>[
          '--open',
          'secret.txt',
        ]).rejection,
        UriRejection.unsupportedArgument,
      );
      expect(
        policy.evaluateDesktopArguments(<String>['file:///tmp/secret']).allowed,
        isFalse,
      );
    });
  });
  group('UriPolicy outbound links', () {
    final UriPolicy policy = UriPolicy(
      externalHosts: const <String>{'docs.example.com'},
    );

    test('requires a user action and an exact HTTPS host', () {
      final Uri approved = Uri.parse('https://docs.example.com/guide');

      expect(
        policy.evaluateOutbound(approved, userInitiated: false).rejection,
        UriRejection.explicitActionRequired,
      );
      expect(
        policy.evaluateOutbound(approved, userInitiated: true).allowed,
        isTrue,
      );
      expect(
        policy
            .evaluateOutbound(
              Uri.parse('https://evil.example/guide'),
              userInitiated: true,
            )
            .rejection,
        UriRejection.untrustedHost,
      );
    });

    test(
      'rejects query content, fragments, credentials, and non-HTTPS URLs',
      () {
        final List<Uri> unsafe = <Uri>[
          Uri.parse('https://docs.example.com/guide?query=private'),
          Uri.parse('https://docs.example.com/guide#private'),
          Uri.parse('https://user@docs.example.com/guide'),
          Uri.parse('http://docs.example.com/guide'),
        ];

        for (final Uri uri in unsafe) {
          expect(
            policy.evaluateOutbound(uri, userInitiated: true).allowed,
            isFalse,
            reason: uri.scheme,
          );
        }
      },
    );
  });
}
