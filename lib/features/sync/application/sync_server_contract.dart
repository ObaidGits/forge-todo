/// The canonical protocol-v2 *server* wire vocabulary and limits shared by the
/// client and the PostgreSQL sync backend (task 9.2; R-SYNC-003, R-SYNC-004,
/// NFR-SEC-002).
///
/// Task 9.1 landed the pure client contracts (epochs, sequences, semantic
/// groups, cursors, field versions, manifest). Task 9.2 implements the server
/// (`supabase/migrations/*.sql`). The two must agree on:
///
///  * the RPC surface names (the *only* write path — direct table writes are
///    denied by RLS);
///  * the string spelling of push outcomes and operation kinds on the wire;
///  * the request/batch/page/payload limits enforced identically on both ends;
///  * the exact set of replicated entity types the server allowlists.
///
/// Keeping this vocabulary in one Dart value means the future transport adapter
/// (task 9.10) and the SQL backend derive their strings from a single reviewed
/// source. `tool/sync_server_lint.py` reads these literals and asserts the SQL
/// migrations spell them the same way and allowlist the same entities as
/// [buildForgeReplicationManifestV1], giving in-repo protocol-compatibility
/// evidence without a live database.
///
/// This file is pure application glue: it has no Drift/Flutter/Supabase imports
/// so the server contract can be reasoned about and tested independently of any
/// backend (R-SYNC-007 replaceable transport).
library;

import 'package:forge/features/sync/domain/semantic_group.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';

/// The names of the reviewed transactional RPC functions that are the *only*
/// sanctioned write path against the server (data-model.md §6 "Mutation occurs
/// only through reviewed transactional functions/endpoints; broad direct writes
/// are denied").
abstract final class SyncServerRpc {
  /// Group-atomic push: accepts or rejects each semantic group as a unit,
  /// rejects a stale epoch before any mutation, deduplicates by group id, and
  /// advances the owner's `server_seq`/change feed atomically.
  static const String push = 'forge.push';

  /// Ordered pull of one contiguous page of changes (plus durable conflict
  /// artifacts) by `server_seq` within an epoch.
  static const String pull = 'forge.pull';

  /// Every sanctioned server write path. Anything else is denied by RLS.
  static const List<String> all = <String>[push, pull];
}

/// The wire spelling of a [SemanticGroupOutcome] in a push response. The SQL
/// `forge.push` RPC emits exactly these strings.
abstract final class SyncGroupOutcomeWire {
  static const String accepted = 'accepted';
  static const String rejected = 'rejected';
  static const String conflict = 'conflict';
  static const String staleEpoch = 'stale_epoch';

  /// Maps an outcome to its wire string.
  static String of(SemanticGroupOutcome outcome) => switch (outcome) {
    SemanticGroupOutcome.accepted => accepted,
    SemanticGroupOutcome.rejected => rejected,
    SemanticGroupOutcome.conflict => conflict,
    SemanticGroupOutcome.staleEpoch => staleEpoch,
  };

  /// Parses a wire string back into an outcome, rejecting unknown values so a
  /// malformed/forged server response cannot be silently misread.
  static SemanticGroupOutcome fromWire(String value) => switch (value) {
    accepted => SemanticGroupOutcome.accepted,
    rejected => SemanticGroupOutcome.rejected,
    conflict => SemanticGroupOutcome.conflict,
    staleEpoch => SemanticGroupOutcome.staleEpoch,
    _ => throw ArgumentError.value(value, 'value', 'Unknown group outcome'),
  };

  /// All wire outcome strings, for conformance checks.
  static const List<String> all = <String>[
    accepted,
    rejected,
    conflict,
    staleEpoch,
  ];
}

/// The wire spelling of a [SyncOperationKind]. Mirrors [SyncOperationKind.wire]
/// so the server and client agree on the operation vocabulary.
abstract final class SyncOperationKindWire {
  static const String insert = 'insert';
  static const String patch = 'patch';
  static const String delete = 'delete';

  static const List<String> all = <String>[insert, patch, delete];
}

/// Hard protocol limits enforced identically by the client (before enqueue) and
/// the server (before mutation). The server rejects an over-limit push/pull
/// before touching any row; the client never builds a batch that exceeds them.
///
/// These bounds cap the blast radius of a single request and keep a group-
/// atomic transaction small enough to commit predictably. Values are chosen to
/// comfortably fit the supported entity payloads while refusing pathological
/// inputs.
abstract final class SyncProtocolLimits {
  /// Maximum semantic groups accepted in one push batch.
  static const int maxGroupsPerPush = 128;

  /// Maximum operations in one semantic group.
  static const int maxOperationsPerGroup = 512;

  /// Maximum operations across a whole push batch (defence-in-depth over the
  /// per-group and per-batch group counts).
  static const int maxOperationsPerPush = 2048;

  /// Maximum changes returned in one pull page.
  static const int maxChangesPerPullPage = 512;

  /// Maximum serialized bytes of a single operation payload.
  static const int maxOperationPayloadBytes = 262144; // 256 KiB

  /// Maximum serialized bytes of a whole push request body.
  static const int maxPushRequestBytes = 4194304; // 4 MiB

  /// The protocol version these limits are defined for.
  static const int protocolVersion = kSyncProtocolVersion;
}
