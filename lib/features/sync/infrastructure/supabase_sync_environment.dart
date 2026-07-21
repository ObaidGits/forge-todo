/// Compile-time sync backend configuration loaded from `--dart-define`
/// (R-SYNC-007, NFR-SEC-002; design.md §8/§13).
///
/// Sync is OFF by default. The default local-first build ships no backend
/// configuration, so [SupabaseSyncEnvironment.fromEnvironment] returns a
/// disabled environment and the composition root never constructs any sync
/// component — local behaviour is completely unchanged.
///
/// Enabling sync requires exactly two build-time defines:
///
/// ```
/// --dart-define=FORGE_SUPABASE_URL=https://<project>.supabase.co \
/// --dart-define=FORGE_SUPABASE_ANON_KEY=<public-anon-key>
/// ```
///
/// plus signing in from the in-app "Account & sync" screen. An `https` URL on
/// the pinned hosted host suffix binds the first-party hosted backend; any other
/// `https` URL binds a self-hosted / compatible backend. A plaintext `http` URL
/// is rejected by [SyncBackendConfig] (TLS is mandatory) — with the sole,
/// explicit exception of a loopback host used for LOCAL end-to-end testing,
/// which [SupabaseSyncEnvironment.local] constructs directly (never from a
/// release build).
library;

// Named constructor parameters bind to private fields; the initializing-formal
// form would leak underscored parameter names into the public API.
// ignore_for_file: prefer_initializing_formals

import 'package:forge/features/sync/domain/sync_backend_config.dart';

/// The two dart-define keys that enable and configure sync.
abstract final class SyncDartDefines {
  static const String url = 'FORGE_SUPABASE_URL';
  static const String anonKey = 'FORGE_SUPABASE_ANON_KEY';
}

/// A resolved sync environment: either disabled (no config) or enabled with a
/// validated [SyncBackendConfig].
final class SupabaseSyncEnvironment {
  const SupabaseSyncEnvironment._({required this.config});

  /// The disabled environment: sync is inert and local-first is unchanged.
  const SupabaseSyncEnvironment.disabled() : config = null;

  /// Reads [SyncDartDefines.url]/[SyncDartDefines.anonKey] from the compile
  /// environment. When either is empty, sync stays disabled. When both are
  /// present the URL scheme/host decides hosted vs self-hosted; a malformed or
  /// non-TLS config throws [SyncBackendConfigException] at construction so a
  /// misconfigured build fails loudly rather than silently syncing plaintext.
  factory SupabaseSyncEnvironment.fromEnvironment() {
    const String url = String.fromEnvironment(SyncDartDefines.url);
    const String anonKey = String.fromEnvironment(SyncDartDefines.anonKey);
    if (url.trim().isEmpty || anonKey.trim().isEmpty) {
      return const SupabaseSyncEnvironment.disabled();
    }
    return SupabaseSyncEnvironment._(config: _configFor(url, anonKey));
  }

  /// Builds an enabled environment for an explicit [config] (used by tests and
  /// by callers that already resolved a config).
  const SupabaseSyncEnvironment.enabled(SyncBackendConfig config)
    : config = config;

  /// The validated backend configuration, or null when sync is disabled.
  final SyncBackendConfig? config;

  /// Whether sync is enabled in this build.
  bool get isEnabled => config != null;

  static SyncBackendConfig _configFor(String url, String anonKey) {
    final Uri? parsed = Uri.tryParse(url.trim());
    final bool hosted =
        parsed != null &&
        parsed.scheme == 'https' &&
        parsed.host.endsWith(ForgeHostedBackend.hostSuffix);
    if (hosted) {
      return SyncBackendConfig.hosted(url: url.trim(), anonKey: anonKey.trim());
    }
    return SyncBackendConfig.selfHosted(
      backendId: _selfHostedIdFor(parsed, url),
      url: url.trim(),
      anonKey: anonKey.trim(),
    );
  }

  /// Derives a stable self-hosted backend id from the endpoint host so a device
  /// holds at most one link per distinct self-hosted endpoint.
  static String _selfHostedIdFor(Uri? parsed, String url) {
    final String host = parsed?.host ?? url.trim();
    return 'self-hosted:$host';
  }
}
