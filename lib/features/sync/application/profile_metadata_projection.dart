/// The special remote-profile-metadata boundary projection (R-SYNC-001,
/// design.md §8, data-model.md §6).
///
/// Remote profile metadata maps onto the *existing* local profile. It is not an
/// ordinary replicated entity insert and can never create, replace, or rekey a
/// `profiles` row. This contract guards that invariant: it only ever updates a
/// mapped projection of the already-present local profile.
library;

import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/sync/domain/remote_change.dart';
import 'package:forge/features/sync/domain/replication_manifest.dart';

/// Raised when a change would create/replace/rekey an ordinary local profile
/// row, which is forbidden.
final class ProfileProjectionException implements Exception {
  const ProfileProjectionException(this.reason);

  final String reason;

  @override
  String toString() => 'ProfileProjectionException: $reason';
}

/// Applies remote profile metadata onto the existing local profile projection.
///
/// Implementations update only the mapped, non-identity metadata (display name,
/// locale/timezone/week preferences, portable settings) of the profile the
/// [localProfileId] already identifies. They MUST NOT insert a new `profiles`
/// row or change an existing profile's ID.
abstract interface class ProfileMetadataProjector {
  /// Projects [change]'s metadata onto the existing local profile within [tx].
  Future<void> project(
    TransactionSession tx, {
    required ProfileId localProfileId,
    required RemoteChange change,
  });
}

/// A guarding decorator that enforces the "no ordinary profile insert/rekey"
/// invariant before delegating to a concrete [ProfileMetadataProjector].
final class GuardedProfileMetadataProjector
    implements ProfileMetadataProjector {
  const GuardedProfileMetadataProjector(this._delegate);

  final ProfileMetadataProjector _delegate;

  @override
  Future<void> project(
    TransactionSession tx, {
    required ProfileId localProfileId,
    required RemoteChange change,
  }) async {
    if (change.entityType != ReplicationManifest.profileMetadataEntity) {
      throw ProfileProjectionException(
        'Only ${ReplicationManifest.profileMetadataEntity} changes may be '
        'projected; got ${change.entityType}.',
      );
    }
    if (change.tombstone) {
      throw const ProfileProjectionException(
        'Remote profile metadata cannot delete the local profile.',
      );
    }
    // A metadata projection targets the already-present local profile. A change
    // whose entity id differs from the mapped local profile would imply
    // creating/rekeying a profile row, which is forbidden.
    if (change.entityId != localProfileId.value) {
      throw ProfileProjectionException(
        'Refusing to project profile metadata onto a different profile id '
        '(${change.entityId} != ${localProfileId.value}); a profiles row is '
        'never created or rekeyed by sync.',
      );
    }
    await _delegate.project(tx, localProfileId: localProfileId, change: change);
  }
}
