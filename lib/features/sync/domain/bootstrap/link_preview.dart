/// Link preview: the non-destructive comparison a device makes before it binds
/// to a remote profile (R-SYNC-001, data-model.md §6 "Link preview compares
/// counts/manifests/root hashes and offers create remote, staged merge, or
/// cancel").
///
/// A preview never mutates local or remote state. It compares the local
/// generation's replicated inventory against the account's existing remote
/// profile (when one exists) and offers exactly one of three explicit choices.
/// Upload-first and replace-local are never offered automatically.
library;

/// A deterministic digest of a replicated scope: the number of replicated
/// entities and a root hash over their canonical content. Two scopes with the
/// same [entityCount] and [rootHash] are considered content-equivalent for the
/// purposes of a link preview.
final class ManifestDigest {
  ManifestDigest({
    required this.protocolVersion,
    required this.entityCount,
    required this.rootHash,
  }) {
    if (protocolVersion < 0) {
      throw ArgumentError.value(
        protocolVersion,
        'protocolVersion',
        'Must be nonnegative.',
      );
    }
    if (entityCount < 0) {
      throw ArgumentError.value(
        entityCount,
        'entityCount',
        'Must be nonnegative.',
      );
    }
    if (rootHash.isEmpty) {
      throw ArgumentError.value(rootHash, 'rootHash', 'Must not be empty.');
    }
  }

  final int protocolVersion;
  final int entityCount;
  final String rootHash;

  bool get isEmpty => entityCount == 0;

  bool matches(ManifestDigest other) =>
      protocolVersion == other.protocolVersion &&
      entityCount == other.entityCount &&
      rootHash == other.rootHash;

  @override
  bool operator ==(Object other) =>
      other is ManifestDigest &&
      other.protocolVersion == protocolVersion &&
      other.entityCount == entityCount &&
      other.rootHash == rootHash;

  @override
  int get hashCode => Object.hash(protocolVersion, entityCount, rootHash);

  @override
  String toString() =>
      'ManifestDigest(v$protocolVersion, n=$entityCount, $rootHash)';
}

/// The three explicit outcomes a link preview offers (R-SYNC-001).
enum LinkAdoptionOption {
  /// No remote profile exists for the account: create one that adopts this
  /// device's local profile id.
  createRemote,

  /// A remote profile exists: stage a merge of local and remote into a shadow
  /// generation, which can be activated or cancelled.
  stagedMerge,

  /// Do nothing: leave local state untouched and stay unlinked.
  cancel,
}

/// Raised when a preview cannot be produced without mutating state — for
/// example an ambiguous or colliding ownership that must abort rather than
/// silently pick a side (R-SYNC-001 "collision or ambiguity fails without local
/// mutation").
final class LinkPreviewException implements Exception {
  const LinkPreviewException(this.reason);

  final String reason;

  @override
  String toString() => 'LinkPreviewException: $reason';
}

/// The immutable result of comparing local state to the account's remote
/// profile (if any). It records the two digests and the offered options.
final class LinkPreview {
  LinkPreview._({
    required this.localDigest,
    required this.remoteDigest,
    required this.recommended,
    required Iterable<LinkAdoptionOption> options,
  }) : options = List<LinkAdoptionOption>.unmodifiable(options);

  /// Builds a preview for a device whose account has no remote profile yet:
  /// the only mutating option is to create a remote profile.
  factory LinkPreview.noRemoteProfile({required ManifestDigest localDigest}) =>
      LinkPreview._(
        localDigest: localDigest,
        remoteDigest: null,
        recommended: LinkAdoptionOption.createRemote,
        options: const <LinkAdoptionOption>[
          LinkAdoptionOption.createRemote,
          LinkAdoptionOption.cancel,
        ],
      );

  /// Builds a preview for a device whose account already owns a remote profile:
  /// the mutating option is a staged merge. When the digests already match, the
  /// merge is a no-op fast-forward but is still surfaced (not auto-applied).
  factory LinkPreview.existingRemoteProfile({
    required ManifestDigest localDigest,
    required ManifestDigest remoteDigest,
  }) => LinkPreview._(
    localDigest: localDigest,
    remoteDigest: remoteDigest,
    recommended: LinkAdoptionOption.stagedMerge,
    options: const <LinkAdoptionOption>[
      LinkAdoptionOption.stagedMerge,
      LinkAdoptionOption.cancel,
    ],
  );

  final ManifestDigest localDigest;

  /// The remote profile's digest, or null when no remote profile exists.
  final ManifestDigest? remoteDigest;

  /// The recommended (non-cancel) option for this preview.
  final LinkAdoptionOption recommended;

  /// Every offered option, always including [LinkAdoptionOption.cancel].
  final List<LinkAdoptionOption> options;

  /// Whether a remote profile already exists for the account.
  bool get hasRemoteProfile => remoteDigest != null;

  /// Whether local and remote already carry identical replicated content.
  bool get isAlreadyConverged =>
      remoteDigest != null && localDigest.matches(remoteDigest!);

  bool offers(LinkAdoptionOption option) => options.contains(option);
}
