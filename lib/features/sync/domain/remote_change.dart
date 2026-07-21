/// A single inbound change delivered by a pull page, already translated to the
/// existing local `profile_id` before a typed applier runs (R-SYNC-003,
/// design.md §8).
///
/// The change carries the server-assigned authority metadata (`server_seq`,
/// `server_version`, per-field versions, tombstone) plus the replicated payload
/// so the feature's typed applier can apply it deterministically.
library;

import 'package:forge/features/sync/domain/field_version.dart';
import 'package:forge/features/sync/domain/semantic_group.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';

/// One authoritative inbound change from the server.
final class RemoteChange {
  RemoteChange({
    required this.changeId,
    required this.entityType,
    required this.entityId,
    required this.kind,
    required this.serverSeq,
    required this.serverVersion,
    required this.payload,
    this.parentEntityId,
    this.fieldVersions,
    this.tombstone = false,
  }) {
    if (serverVersion < 0) {
      throw ArgumentError.value(
        serverVersion,
        'serverVersion',
        'Must be nonnegative.',
      );
    }
  }

  final String changeId;
  final String entityType;
  final String entityId;
  final SyncOperationKind kind;
  final ServerSeq serverSeq;
  final int serverVersion;

  /// The replicated payload for this change; local-only/server-only fields are
  /// never present.
  final Map<String, Object?> payload;

  /// The strict-parent entity ID for parent-before-child apply ordering.
  final String? parentEntityId;

  final FieldVersionMap? fieldVersions;

  /// True when the change is a tombstone (soft-delete marker).
  final bool tombstone;
}
