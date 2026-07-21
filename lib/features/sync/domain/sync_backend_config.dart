/// Replaceable sync-backend configuration (R-SYNC-007, NFR-SEC-002; design.md
/// §8/§13).
///
/// R-SYNC-007 requires that the backend is replaceable: hosted Supabase, a
/// self-hosted Supabase, or a compatible future service, all without changing
/// domain repositories. This value is the client's pinned/validated description
/// of *which* protocol-v2 backend a link talks to. Its [backendId] is exactly
/// the [SyncProfileLink.backend] discriminator, so a device can hold at most one
/// link per backend.
///
/// Validation enforces the trust and safety invariants:
///
///   * every endpoint uses `https` — sync transport is TLS-protected
///     (NFR-SEC-002), never plaintext `http`;
///   * a self-hosted backend URL must be explicitly configured (there is no
///     safe default self-host endpoint);
///   * the pinned hosted backend uses a fixed backend id and its endpoint host
///     must match the pinned hosted host suffix; and
///   * the supplied key must be a public anon key, never a service-role secret
///     (NFR-SEC-002 "service-role secrets SHALL never ship in clients").
///
/// This is a pure domain value: no Drift/Flutter/Supabase imports, so backend
/// configuration can be reasoned about and tested independently of any adapter.
library;

import 'package:forge/features/sync/domain/sync_protocol.dart';

/// The kind of protocol-v2 backend a config describes (R-SYNC-007).
enum SyncBackendKind {
  /// The pinned first-party hosted Supabase backend.
  hostedSupabase('hosted-supabase'),

  /// An operator-run self-hosted Supabase instance.
  selfHostedSupabase('self-hosted-supabase'),

  /// A future service that honours protocol v2. Reuses the same contract.
  compatibleFuture('compatible-future');

  const SyncBackendKind(this.wire);

  final String wire;
}

/// Identifiers and pins for the first-party hosted backend. The hosted endpoint
/// is pinned by host suffix rather than a single literal URL so a region/subdomain
/// can vary without loosening the check to arbitrary hosts.
abstract final class ForgeHostedBackend {
  /// The stable backend id used as the [SyncProfileLink.backend] discriminator
  /// for the hosted backend.
  static const String backendId = 'forge-hosted-supabase';

  /// The host suffix a hosted endpoint must end with. Any hosted URL must be an
  /// `https` URL whose host ends with this suffix.
  static const String hostSuffix = '.supabase.co';
}

/// Raised when a backend configuration is invalid — a non-TLS endpoint, a
/// missing self-host URL, a hosted URL outside the pinned host, an empty
/// backend id/key, or a key that looks like a service-role secret.
final class SyncBackendConfigException implements Exception {
  const SyncBackendConfigException(this.reason);

  final String reason;

  @override
  String toString() => 'SyncBackendConfigException: $reason';
}

/// A validated, replaceable backend configuration.
final class SyncBackendConfig {
  SyncBackendConfig._({
    required this.backendId,
    required this.kind,
    required this.url,
    required this.anonKey,
    required this.protocolVersion,
  });

  /// Builds the pinned first-party hosted configuration. The endpoint must be
  /// an `https` URL on the pinned hosted host suffix; the [anonKey] is a public
  /// anon key supplied by build configuration (never a hardcoded secret).
  factory SyncBackendConfig.hosted({
    required String url,
    required String anonKey,
    int protocolVersion = kSyncProtocolVersion,
  }) {
    final Uri endpoint = _validatedHttpsUri(url);
    if (!endpoint.host.endsWith(ForgeHostedBackend.hostSuffix)) {
      throw SyncBackendConfigException(
        'The pinned hosted backend endpoint host must end with '
        '"${ForgeHostedBackend.hostSuffix}"; got "${endpoint.host}".',
      );
    }
    return SyncBackendConfig._(
      backendId: ForgeHostedBackend.backendId,
      kind: SyncBackendKind.hostedSupabase,
      url: endpoint,
      anonKey: _validatedAnonKey(anonKey),
      protocolVersion: _validatedProtocol(protocolVersion),
    );
  }

  /// Builds a self-hosted configuration. There is no default self-host
  /// endpoint: the operator must explicitly configure a non-empty `https` URL.
  factory SyncBackendConfig.selfHosted({
    required String backendId,
    required String url,
    required String anonKey,
    int protocolVersion = kSyncProtocolVersion,
  }) {
    if (url.trim().isEmpty) {
      throw const SyncBackendConfigException(
        'A self-hosted backend requires an explicitly configured URL.',
      );
    }
    return SyncBackendConfig._(
      backendId: _validatedBackendId(backendId),
      kind: SyncBackendKind.selfHostedSupabase,
      url: _validatedHttpsUri(url),
      anonKey: _validatedAnonKey(anonKey),
      protocolVersion: _validatedProtocol(protocolVersion),
    );
  }

  /// Builds a configuration for a compatible future service. Like self-host, it
  /// must be explicitly configured with an `https` endpoint.
  factory SyncBackendConfig.compatible({
    required String backendId,
    required String url,
    required String anonKey,
    int protocolVersion = kSyncProtocolVersion,
  }) {
    if (url.trim().isEmpty) {
      throw const SyncBackendConfigException(
        'A compatible backend requires an explicitly configured URL.',
      );
    }
    return SyncBackendConfig._(
      backendId: _validatedBackendId(backendId),
      kind: SyncBackendKind.compatibleFuture,
      url: _validatedHttpsUri(url),
      anonKey: _validatedAnonKey(anonKey),
      protocolVersion: _validatedProtocol(protocolVersion),
    );
  }

  /// The [SyncProfileLink.backend] discriminator this config configures.
  final String backendId;

  /// Which kind of backend this describes.
  final SyncBackendKind kind;

  /// The validated `https` endpoint.
  final Uri url;

  /// The public anon key used to reach the backend.
  final String anonKey;

  /// The protocol version this configuration targets.
  final int protocolVersion;

  /// Whether this configuration targets the pinned first-party hosted backend.
  bool get isHosted => kind == SyncBackendKind.hostedSupabase;

  /// Whether an operator must supply the endpoint (self-host / compatible).
  bool get requiresExplicitEndpoint => !isHosted;

  static Uri _validatedHttpsUri(String url) {
    final Uri? parsed = Uri.tryParse(url.trim());
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      throw SyncBackendConfigException('Malformed backend URL: "$url".');
    }
    if (parsed.scheme != 'https') {
      throw SyncBackendConfigException(
        'Backend transport must use TLS (https); got scheme '
        '"${parsed.scheme}".',
      );
    }
    return parsed;
  }

  static String _validatedBackendId(String backendId) {
    final String trimmed = backendId.trim();
    if (trimmed.isEmpty) {
      throw const SyncBackendConfigException('Backend id must not be empty.');
    }
    if (trimmed == ForgeHostedBackend.backendId) {
      throw SyncBackendConfigException(
        'Backend id "${ForgeHostedBackend.backendId}" is reserved for the '
        'pinned hosted backend; use SyncBackendConfig.hosted.',
      );
    }
    return trimmed;
  }

  static String _validatedAnonKey(String anonKey) {
    final String trimmed = anonKey.trim();
    if (trimmed.isEmpty) {
      throw const SyncBackendConfigException('Backend key must not be empty.');
    }
    // Reject an obvious service-role secret. Supabase service-role keys carry a
    // `"role":"service_role"` claim (base64url-encoded in a JWT) or are labelled
    // as such; a client must only ever hold a public anon key (NFR-SEC-002).
    final String lower = trimmed.toLowerCase();
    if (lower.contains('service_role') || lower.contains('service-role')) {
      throw const SyncBackendConfigException(
        'Refusing a service-role secret: clients may only hold a public anon '
        'key (NFR-SEC-002).',
      );
    }
    return trimmed;
  }

  static int _validatedProtocol(int protocolVersion) {
    if (protocolVersion != kSyncProtocolVersion) {
      throw SyncBackendConfigException(
        'Unsupported protocol version $protocolVersion; this client speaks v'
        '$kSyncProtocolVersion.',
      );
    }
    return protocolVersion;
  }

  @override
  String toString() =>
      'SyncBackendConfig($backendId, ${kind.wire}, $url, v$protocolVersion)';
}
