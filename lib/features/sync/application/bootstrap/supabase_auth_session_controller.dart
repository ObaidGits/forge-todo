/// Adapts the task 9.4 [SupabaseAuthStateMachine] onto the narrow
/// [AuthSessionController] port the adoption flow drives (R-SYNC-001,
/// R-SYNC-008).
///
/// Keeping the adapter here means the adoption service depends only on the port
/// and stays testable with a deterministic fake, while production wiring binds
/// it to the real, fully-configured auth state machine.
library;

import 'package:forge/core/domain/result.dart';
import 'package:forge/features/sync/application/auth/supabase_auth_state_machine.dart';
import 'package:forge/features/sync/application/bootstrap/bootstrap_ports.dart';

/// A thin adapter from the Supabase auth state machine to
/// [AuthSessionController].
final class SupabaseAuthSessionController implements AuthSessionController {
  const SupabaseAuthSessionController(this._machine);

  final SupabaseAuthStateMachine _machine;

  @override
  void bindLinked(bool linked) => _machine.bindLinked(linked);

  @override
  bool get hasRecentReauthentication => _machine.hasRecentReauthentication;

  @override
  void requireRemoteDeleteReauth() => _machine.requireRemoteDeleteReauth();

  @override
  Future<Result<bool>> signOut({required bool retainLocalData}) =>
      _machine.signOut(retainLocalData: retainLocalData);
}
