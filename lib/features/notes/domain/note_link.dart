import 'package:forge/core/domain/id.dart';

/// The resolution state of a `[[wiki-link]]` target (R-NOTE-003).
///
/// A link is [resolved] to exactly one live note, [ambiguous] when more than
/// one live note shares the target title (the user MUST pick explicitly rather
/// than have Forge silently bind one), or [unresolved] when no live note
/// currently matches. Deleting a target demotes inbound links to [unresolved]
/// (a recoverable reference), and restore/rename re-resolve deterministically.
enum WikiLinkResolution {
  resolved,
  ambiguous,
  unresolved;

  /// The stable lowercase wire value stored in `note_links.resolution`.
  String get wire => name;

  /// Decodes a stored value with unknown-safe fallback to [unresolved]
  /// (data-model §1 unknown-safe enum decoding).
  static WikiLinkResolution fromWire(String? value) {
    switch (value) {
      case 'resolved':
        return WikiLinkResolution.resolved;
      case 'ambiguous':
        return WikiLinkResolution.ambiguous;
      default:
        return WikiLinkResolution.unresolved;
    }
  }

  /// Classifies a target from the live candidate ids that matched the link's
  /// normalized target (self already excluded by the caller). Zero candidates
  /// is [unresolved], exactly one is [resolved], and more than one is
  /// [ambiguous] — the single deterministic rule shared by outgoing
  /// maintenance and inbound re-resolution.
  static WikiLinkResolution classify(List<String> candidates) {
    if (candidates.isEmpty) {
      return WikiLinkResolution.unresolved;
    }
    if (candidates.length == 1) {
      return WikiLinkResolution.resolved;
    }
    return WikiLinkResolution.ambiguous;
  }
}

/// An outgoing `[[wiki-link]]` from one note to another (R-NOTE-003).
///
/// A link records the source note, the raw target title, the exact source range
/// of the `[[...]]` span, the [resolution] state, and the [targetNoteId] when
/// exactly one live note matches. Ambiguous/unresolved links keep
/// [targetNoteId] null while preserving [normalizedTarget] so a rename,
/// restore, or explicit selection can re-resolve them deterministically.
final class NoteLink {
  const NoteLink({
    required this.id,
    required this.profileId,
    required this.sourceNoteId,
    required this.targetTitle,
    required this.normalizedTarget,
    required this.label,
    required this.sourceStart,
    required this.sourceEnd,
    this.targetNoteId,
    this.resolution = WikiLinkResolution.unresolved,
  });

  final String id;
  final ProfileId profileId;
  final NoteId sourceNoteId;

  /// The raw referenced title text.
  final String targetTitle;

  /// The normalized (case/whitespace-folded) target used for resolution.
  final String normalizedTarget;

  final String label;
  final int sourceStart;
  final int sourceEnd;

  /// The resolved target note, or null when unresolved/ambiguous.
  final NoteId? targetNoteId;

  /// The explicit resolution state (R-NOTE-003).
  final WikiLinkResolution resolution;

  bool get isResolved => resolution == WikiLinkResolution.resolved;

  /// True when the link points at multiple candidates and needs an explicit
  /// user selection rather than a silent bind (R-NOTE-003).
  bool get isAmbiguous => resolution == WikiLinkResolution.ambiguous;
}

/// Case- and whitespace-folded normalization for note titles and wiki-link
/// targets, so `[[My Note]]` resolves to a note titled "my   note".
String normalizeNoteTitle(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
