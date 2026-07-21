/// Deterministic in-memory fakes for the bootstrap/adoption ports (task 9.5).
///
/// None of these touch a network, disk, or database: the whole bootstrap
/// orchestration is exercised as pure application logic. The real
/// [CommandQuiescenceGate] and [JournalReplayRebaser] are used directly; only
/// the side-effecting seams are faked here.
library;

// Named constructor parameters use public names bound to private fields.
// ignore_for_file: prefer_initializing_formals

import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/sync/application/bootstrap/bootstrap_ports.dart';
import 'package:forge/features/sync/domain/bootstrap/link_preview.dart';
import 'package:forge/features/sync/domain/bootstrap/local_inventory.dart';
import 'package:forge/features/sync/domain/remote_change.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';

String _key(String entityType, String entityId) => '$entityType:$entityId';

/// An in-memory staged generation that records every operation applied to it.
final class RecordingStagedGeneration implements StagedGeneration {
  RecordingStagedGeneration({
    required this.epoch,
    Map<String, int> baseVersions = const <String, int>{},
    this.failActivation = false,
  }) : _baseVersions = Map<String, int>.of(baseVersions);

  @override
  final int epoch;

  final Map<String, int> _baseVersions;

  /// When true, [activate] throws to model a failed atomic switch.
  final bool failActivation;

  final List<LocalOnlyItem> copiedLocalOnly = <LocalOnlyItem>[];
  final List<ReceiptRecord> importedReceipts = <ReceiptRecord>[];
  final List<StagedGroupDraft> newGroups = <StagedGroupDraft>[];
  final List<StagedConflictDraft> conflicts = <StagedConflictDraft>[];
  final List<RemoteChange> pulledChanges = <RemoteChange>[];

  bool activated = false;
  bool discarded = false;

  @override
  Future<int?> stagedVersionOf(String entityType, String entityId) async =>
      _baseVersions[_key(entityType, entityId)];

  @override
  Future<void> copyLocalOnly(LocalOnlyItem item) async {
    copiedLocalOnly.add(item);
  }

  @override
  Future<void> importReceipt(ReceiptRecord receipt) async {
    importedReceipts.add(receipt);
  }

  @override
  Future<void> recordNewEpochGroup(StagedGroupDraft group) async {
    newGroups.add(group);
    _baseVersions[_key(group.entityType, group.entityId)] = group.newRowVersion;
  }

  @override
  Future<void> recordDurableConflict(StagedConflictDraft conflict) async {
    conflicts.add(conflict);
  }

  @override
  Future<void> applyPulledChange(RemoteChange change) async {
    pulledChanges.add(change);
    _baseVersions[_key(change.entityType, change.entityId)] =
        change.serverVersion;
  }

  @override
  Future<void> activate() async {
    if (discarded) {
      throw StateError('Cannot activate a discarded staged generation.');
    }
    if (failActivation) {
      throw StateError('Simulated activation failure.');
    }
    activated = true;
  }

  @override
  Future<void> discard() async {
    discarded = true;
  }
}

/// Builds a [RecordingStagedGeneration] from a preset base-version map.
final class FakeStagedGenerationBuilder implements StagedGenerationBuilder {
  FakeStagedGenerationBuilder({
    Map<String, int> baseVersions = const <String, int>{},
    this.failBuild = false,
    this.failActivation = false,
  }) : _baseVersions = Map<String, int>.of(baseVersions);

  final Map<String, int> _baseVersions;
  final bool failBuild;
  final bool failActivation;

  final List<RecordingStagedGeneration> built = <RecordingStagedGeneration>[];

  RecordingStagedGeneration get last => built.last;

  @override
  Future<StagedGeneration> build({
    required ProfileId profile,
    required int baseEpoch,
    required int watermark,
  }) async {
    if (failBuild) {
      throw StateError('Simulated staging build failure.');
    }
    final RecordingStagedGeneration staged = RecordingStagedGeneration(
      epoch: baseEpoch,
      baseVersions: _baseVersions,
      failActivation: failActivation,
    );
    built.add(staged);
    return staged;
  }
}

/// Returns a preset inventory for any profile.
final class FakeLocalGenerationInventory implements LocalGenerationInventory {
  FakeLocalGenerationInventory(this._inventory);

  final LocalInventory _inventory;

  int inventoryCalls = 0;

  @override
  Future<LocalInventory> inventory(ProfileId profile) async {
    inventoryCalls += 1;
    return _inventory;
  }
}

/// A configurable remote gateway: an optional existing profile plus a preset
/// post-watermark pull page.
final class FakeRemoteBootstrapGateway implements RemoteBootstrapGateway {
  FakeRemoteBootstrapGateway({
    RemoteProfileSnapshot? remoteProfile,
    List<RemoteChange> pullPage = const <RemoteChange>[],
  }) : _remoteProfile = remoteProfile,
       _pullPage = List<RemoteChange>.of(pullPage);

  final RemoteProfileSnapshot? _remoteProfile;
  final List<RemoteChange> _pullPage;

  @override
  Future<RemoteProfileSnapshot?> lookupRemoteProfile(OwnerUserId owner) async =>
      _remoteProfile;

  @override
  Future<List<RemoteChange>> pullPostWatermark({
    required RemoteProfileId remoteProfileId,
    required int epoch,
    required int watermark,
  }) async => List<RemoteChange>.of(_pullPage);
}

/// A verifier that passes by default or fails with a preset reason.
final class FakeManifestVerifier implements BootstrapManifestVerifier {
  FakeManifestVerifier({this.failureReason});

  final String? failureReason;

  @override
  Future<ManifestVerification> verify({
    required StagedGeneration staged,
    required LocalInventory inventory,
  }) async {
    final String? reason = failureReason;
    return reason == null
        ? ManifestVerification.passed()
        : ManifestVerification.failed(reason);
  }
}

/// An in-memory link store keyed by local profile id.
final class InMemorySyncProfileLinkStore implements SyncProfileLinkStore {
  final Map<String, SyncProfileLink> _links = <String, SyncProfileLink>{};

  @override
  Future<SyncProfileLink?> read(ProfileId localProfile) async =>
      _links[localProfile.value];

  @override
  Future<void> save(SyncProfileLink link) async {
    _links[link.localProfileId.value] = link;
  }

  @override
  Future<void> delete(ProfileId localProfile) async {
    _links.remove(localProfile.value);
  }
}

/// A local-digest source returning a preset digest.
final class FakeLocalManifestDigestSource implements LocalManifestDigestSource {
  FakeLocalManifestDigestSource(this._digest);

  final ManifestDigest _digest;

  @override
  Future<ManifestDigest> localDigest(ProfileId profile) async => _digest;
}

/// Records remote-profile deletions.
final class FakeRemoteProfileDeleter implements RemoteProfileDeleter {
  final List<String> deleted = <String>[];

  @override
  Future<void> deleteRemoteProfile(RemoteProfileId remoteProfileId) async {
    deleted.add(remoteProfileId.value);
  }
}

/// A deterministic auth session fake.
final class FakeAuthSessionController implements AuthSessionController {
  FakeAuthSessionController({this.recentReauth = false});

  bool linked = false;
  bool recentReauth;
  bool remoteDeleteReauthRequested = false;
  bool signOutCalled = false;
  bool? signOutRetainLocal;

  @override
  void bindLinked(bool linked) {
    this.linked = linked;
  }

  @override
  bool get hasRecentReauthentication => recentReauth;

  @override
  void requireRemoteDeleteReauth() {
    remoteDeleteReauthRequested = true;
  }

  @override
  Future<Result<bool>> signOut({required bool retainLocalData}) async {
    signOutCalled = true;
    signOutRetainLocal = retainLocalData;
    return Success<bool>(retainLocalData);
  }
}
