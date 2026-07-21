/// Replaceable, validated sync-backend configuration (R-SYNC-007,
/// NFR-SEC-002).
///
/// The backend is replaceable (hosted / self-hosted / compatible) without
/// touching domain repositories, but every configuration is TLS-only, a
/// self-host URL must be explicitly configured, the pinned hosted host is
/// enforced, and a service-role secret is refused. Property tests fuzz the URL
/// scheme and key shape; examples anchor the boundaries.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/sync_backend_config.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';

import '../helpers/evidence.dart';

EvidenceMetadata _evidence(
  String suffix, {
  List<String> requirements = const <String>['R-SYNC-007', 'NFR-SEC-002'],
}) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-BACKEND-CONFIG-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.10'),
  requirements: requirements
      .map((String id) => RequirementId(id))
      .toList(growable: false),
);

const String _anonKey = 'anon-public-key-abc123';

void main() {
  group('hosted (pinned) configuration', () {
    testWithEvidence(
      _evidence('HOSTED-PINNED-BACKEND-ID'),
      'the hosted config uses the pinned backend id on the pinned host',
      () {
        final SyncBackendConfig config = SyncBackendConfig.hosted(
          url: 'https://forge-abcdefgh.supabase.co',
          anonKey: _anonKey,
        );
        expect(config.backendId, ForgeHostedBackend.backendId);
        expect(config.kind, SyncBackendKind.hostedSupabase);
        expect(config.isHosted, isTrue);
        expect(config.requiresExplicitEndpoint, isFalse);
        expect(config.protocolVersion, kSyncProtocolVersion);
      },
    );

    testWithEvidence(
      _evidence('HOSTED-REJECTS-OFF-HOST'),
      'a hosted URL outside the pinned host suffix is rejected',
      () {
        expect(
          () => SyncBackendConfig.hosted(
            url: 'https://evil.example.com',
            anonKey: _anonKey,
          ),
          throwsA(isA<SyncBackendConfigException>()),
        );
      },
    );
  });

  group('self-hosted configuration', () {
    testWithEvidence(
      _evidence('SELF-HOST-REQUIRES-EXPLICIT-URL'),
      'a self-hosted backend requires an explicitly configured URL',
      () {
        expect(
          () => SyncBackendConfig.selfHosted(
            backendId: 'my-forge',
            url: '',
            anonKey: _anonKey,
          ),
          throwsA(isA<SyncBackendConfigException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('SELF-HOST-ACCEPTS-OPERATOR-HTTPS'),
      'a self-hosted backend accepts an operator https endpoint on any host',
      () {
        final SyncBackendConfig config = SyncBackendConfig.selfHosted(
          backendId: 'my-forge',
          url: 'https://forge.mycompany.internal',
          anonKey: _anonKey,
        );
        expect(config.kind, SyncBackendKind.selfHostedSupabase);
        expect(config.backendId, 'my-forge');
        expect(config.requiresExplicitEndpoint, isTrue);
        expect(config.url.host, 'forge.mycompany.internal');
      },
    );

    testWithEvidence(
      _evidence('SELF-HOST-CANNOT-REUSE-HOSTED-ID'),
      'a self-hosted backend cannot claim the reserved hosted backend id',
      () {
        expect(
          () => SyncBackendConfig.selfHosted(
            backendId: ForgeHostedBackend.backendId,
            url: 'https://forge.mycompany.internal',
            anonKey: _anonKey,
          ),
          throwsA(isA<SyncBackendConfigException>()),
        );
      },
    );
  });

  group('TLS and secret invariants', () {
    testWithEvidence(
      _evidence('REJECTS-PLAINTEXT-HTTP'),
      'a plaintext http endpoint is rejected (transport must use TLS)',
      () {
        expect(
          () => SyncBackendConfig.selfHosted(
            backendId: 'my-forge',
            url: 'http://forge.mycompany.internal',
            anonKey: _anonKey,
          ),
          throwsA(isA<SyncBackendConfigException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('REJECTS-SERVICE-ROLE-KEY'),
      'a service-role secret is refused for any backend kind',
      () {
        expect(
          () => SyncBackendConfig.selfHosted(
            backendId: 'my-forge',
            url: 'https://forge.mycompany.internal',
            anonKey: 'eyJ...role...service_role...secret',
          ),
          throwsA(isA<SyncBackendConfigException>()),
        );
        expect(
          () => SyncBackendConfig.hosted(
            url: 'https://forge-abcdefgh.supabase.co',
            anonKey: 'SERVICE-ROLE-master-key',
          ),
          throwsA(isA<SyncBackendConfigException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('REJECTS-EMPTY-KEY'),
      'an empty backend key is rejected',
      () {
        expect(
          () => SyncBackendConfig.selfHosted(
            backendId: 'my-forge',
            url: 'https://forge.mycompany.internal',
            anonKey: '   ',
          ),
          throwsA(isA<SyncBackendConfigException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('REJECTS-UNSUPPORTED-PROTOCOL'),
      'a config for an unsupported protocol version is rejected',
      () {
        expect(
          () => SyncBackendConfig.selfHosted(
            backendId: 'my-forge',
            url: 'https://forge.mycompany.internal',
            anonKey: _anonKey,
            protocolVersion: kSyncProtocolVersion + 1,
          ),
          throwsA(isA<SyncBackendConfigException>()),
        );
      },
    );
  });

  group('property: only https endpoints are ever accepted', () {
    testWithEvidence(
      _evidence('PROP-TLS-ONLY'),
      'across generated schemes, only https produces a valid config',
      () {
        const List<String> schemes = <String>[
          'http',
          'https',
          'ftp',
          'ws',
          'wss',
          'file',
          'supabase',
        ];
        for (int seed = 0; seed < 200; seed += 1) {
          final Random rng = Random(seed);
          final String scheme = schemes[rng.nextInt(schemes.length)];
          final String host = 'forge${rng.nextInt(1000)}.internal';
          final String url = '$scheme://$host';
          if (scheme == 'https') {
            final SyncBackendConfig config = SyncBackendConfig.selfHosted(
              backendId: 'my-forge',
              url: url,
              anonKey: _anonKey,
            );
            expect(config.url.scheme, 'https', reason: 'seed=$seed');
          } else {
            expect(
              () => SyncBackendConfig.selfHosted(
                backendId: 'my-forge',
                url: url,
                anonKey: _anonKey,
              ),
              throwsA(isA<SyncBackendConfigException>()),
              reason: 'non-TLS scheme "$scheme" accepted at seed=$seed',
            );
          }
        }
      },
    );
  });
}
