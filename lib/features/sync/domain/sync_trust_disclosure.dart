/// The user-facing sync trust-model disclosure (R-SYNC-007, NFR-SEC-002;
/// design.md §13 "Network sync is TLS-protected, not E2EE").
///
/// Forge's optional sync is honest about its trust model. Before a user links a
/// device to any backend — hosted Supabase, self-hosted Supabase, or a
/// compatible future service — the client SHALL disclose that:
///
///   * data in transit is protected by TLS;
///   * sync is **not** end-to-end encrypted; and
///   * an authenticated server operator can read synced content.
///
/// It also states the two guarantees that bound that trust (NFR-SEC-002): every
/// synced row is restricted to its owner by row-level security, and no
/// service-role secret ever ships in the client.
///
/// This is a pure domain value: no Drift/Flutter/Supabase imports, so the
/// disclosure content and the "must be acknowledged before linking" rule can be
/// reasoned about and tested independently of any UI or backend.
library;

/// One atomic fact in the trust disclosure. Each point has a stable [code] so a
/// test (or an accessibility layer) can assert a specific fact is present
/// without matching on human copy.
enum SyncTrustFact {
  /// Data in transit is protected by TLS.
  tlsInTransit('tls-in-transit'),

  /// Sync is not end-to-end encrypted.
  notEndToEndEncrypted('not-end-to-end-encrypted'),

  /// An authenticated server operator can read synced content.
  operatorCanReadContent('operator-can-read-content'),

  /// Every synced row is restricted to its owner by row-level security.
  rowLevelSecurity('row-level-security'),

  /// No service-role secret ships in the client.
  noServiceRoleSecretInClient('no-service-role-secret-in-client');

  const SyncTrustFact(this.code);

  /// Stable machine-readable identifier for the fact.
  final String code;
}

/// The canonical, versioned trust disclosure the client presents before
/// linking. Immutable value; the presentation layer renders [title], [summary]
/// and one line per [SyncTrustFact], and the link flow requires a matching
/// [SyncTrustDisclosureAcknowledgement].
final class SyncTrustDisclosure {
  const SyncTrustDisclosure._({
    required this.version,
    required this.title,
    required this.summary,
    required this.facts,
    required this.factCopy,
  });

  /// The current disclosure. Bumping [version] invalidates prior
  /// acknowledgements so a materially changed trust model must be re-shown.
  static const SyncTrustDisclosure current = SyncTrustDisclosure._(
    version: 1,
    title: 'How Forge sync protects your data',
    summary:
        'Sync is optional. Forge works fully offline without it. If you link '
        'a device, here is exactly how your synced data is protected — and '
        'what it is not protected from.',
    facts: <SyncTrustFact>[
      SyncTrustFact.tlsInTransit,
      SyncTrustFact.notEndToEndEncrypted,
      SyncTrustFact.operatorCanReadContent,
      SyncTrustFact.rowLevelSecurity,
      SyncTrustFact.noServiceRoleSecretInClient,
    ],
    factCopy: <SyncTrustFact, String>{
      SyncTrustFact.tlsInTransit:
          'Your data is encrypted in transit with TLS between this device and '
          'the backend.',
      SyncTrustFact.notEndToEndEncrypted:
          'Sync is NOT end-to-end encrypted. Your data is stored so the '
          'backend can process it.',
      SyncTrustFact.operatorCanReadContent:
          'An authenticated operator of the backend can read your synced '
          'content. Only link a backend you trust.',
      SyncTrustFact.rowLevelSecurity:
          'Row-level security restricts every synced row to your account so '
          'other users cannot read it.',
      SyncTrustFact.noServiceRoleSecretInClient:
          'Forge never ships a service-role secret in the app; the client can '
          'only act as your authenticated account.',
    },
  );

  /// The disclosure version. Acknowledgements are bound to this value.
  final int version;

  /// Human-readable heading.
  final String title;

  /// Human-readable summary shown above the individual facts.
  final String summary;

  /// The ordered facts the disclosure asserts. Always includes the mandatory
  /// TLS and non-E2EE honesty facts.
  final List<SyncTrustFact> facts;

  final Map<SyncTrustFact, String> factCopy;

  /// The mandatory honesty facts every disclosure must present (R-SYNC-007,
  /// NFR-SEC-002). A disclosure omitting any of these is invalid.
  static const List<SyncTrustFact> mandatoryFacts = <SyncTrustFact>[
    SyncTrustFact.tlsInTransit,
    SyncTrustFact.notEndToEndEncrypted,
    SyncTrustFact.operatorCanReadContent,
  ];

  /// Whether this disclosure presents [fact].
  bool discloses(SyncTrustFact fact) => facts.contains(fact);

  /// The rendered copy for [fact], or throws if the fact is not disclosed.
  String copyFor(SyncTrustFact fact) {
    final String? copy = factCopy[fact];
    if (copy == null || !discloses(fact)) {
      throw ArgumentError.value(fact, 'fact', 'Fact is not disclosed.');
    }
    return copy;
  }

  /// True when the disclosure presents every mandatory honesty fact and copy
  /// exists for each presented fact. A disclosure that is not complete must
  /// never be used to gate linking.
  bool get isComplete =>
      mandatoryFacts.every(discloses) &&
      facts.every((SyncTrustFact fact) => factCopy.containsKey(fact));

  /// Produces an acknowledgement bound to this disclosure's [version]. The
  /// caller records this once the user has seen and accepted the disclosure.
  SyncTrustDisclosureAcknowledgement acknowledge() =>
      SyncTrustDisclosureAcknowledgement(disclosureVersion: version);
}

/// A durable record that the user was shown and accepted a specific disclosure
/// version. An acknowledgement only satisfies the link gate when its
/// [disclosureVersion] matches the disclosure currently in force, so a bumped
/// disclosure forces a fresh acknowledgement.
final class SyncTrustDisclosureAcknowledgement {
  const SyncTrustDisclosureAcknowledgement({required this.disclosureVersion});

  final int disclosureVersion;

  /// Whether this acknowledgement matches [disclosure] and may gate linking.
  bool isCurrentFor(SyncTrustDisclosure disclosure) =>
      disclosureVersion == disclosure.version;

  @override
  bool operator ==(Object other) =>
      other is SyncTrustDisclosureAcknowledgement &&
      other.disclosureVersion == disclosureVersion;

  @override
  int get hashCode => disclosureVersion.hashCode;

  @override
  String toString() =>
      'SyncTrustDisclosureAcknowledgement(v$disclosureVersion)';
}
