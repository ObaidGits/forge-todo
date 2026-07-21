import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/features/backup/application/recovery_center.dart';

// ---------------------------------------------------------------------------
// Backup / recovery composition seams. Defaults keep the running app honest
// before the encrypted runtime is wired; the composition root and tests
// override them. The backup feature owns its own seams so its presentation
// never imports another feature's presentation, and never touches backup
// infrastructure directly (design.md §4). The presentation depends only on the
// application port [RecoveryCenter] plus the pure application/domain types.
// ---------------------------------------------------------------------------

/// The recovery-center port backing the Recovery Center surface (R-BACKUP-003,
/// R-BACKUP-004). Null until the composition root binds a concrete
/// implementation, in which case the surface shows an honest "no recovery
/// points" state rather than blanking.
final Provider<RecoveryCenter?> recoveryCenterProvider =
    Provider<RecoveryCenter?>((Ref ref) => null);

/// Whether the recovery center is wired at all. Used by the surface to
/// distinguish "not configured in this build" from "configured but empty".
final Provider<bool> recoveryCenterConfiguredProvider = Provider<bool>(
  (Ref ref) => ref.watch(recoveryCenterProvider) != null,
);
