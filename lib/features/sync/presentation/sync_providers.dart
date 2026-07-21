/// Presentation-layer providers for the optional Supabase sync feature.
///
/// The default local-first build leaves [supabaseSyncServiceProvider] at its
/// safe `null` default, so the "Account & sync" surface renders an honest
/// "sync not configured" state and nothing else changes. When a backend is
/// configured (two dart-defines present) the composition root overrides the
/// provider with the constructed [SupabaseSyncService].
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/features/sync/infrastructure/supabase_sync_service.dart';

/// The sync service, or null when sync is disabled in this build.
final Provider<SupabaseSyncService?> supabaseSyncServiceProvider =
    Provider<SupabaseSyncService?>((Ref ref) => null);

/// Whether the optional sync feature is enabled (a service is wired).
final Provider<bool> syncEnabledProvider = Provider<bool>(
  (Ref ref) => ref.watch(supabaseSyncServiceProvider) != null,
);
