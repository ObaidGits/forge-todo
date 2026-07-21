import 'package:forge/core/domain/id.dart';
import 'package:forge/features/notes/domain/note_rank.dart';

/// An immutable note aggregate (R-NOTE-001, R-NOTE-002).
///
/// A note is a top-level direct-area owner: it carries `(profile_id,
/// life_area_id)` (data-model §1/§3). The UTF-8 Markdown [body] is the single
/// canonical source of truth for note content — tasks, goals, roadmaps and
/// Learning Resources reference a note through its id rather than duplicating
/// text (R-TASK-010). [contentHash] is a deterministic fingerprint of the
/// canonical title+body used for change detection and the hash index.
///
/// Classification state is intrinsic to the note: [pinned] and [archivedAtUtc]
/// are note columns, while trash (`deletedAtUtc`) reuses the shared deletion
/// kernel and tags/area are maintained through `entity_tags` and
/// `life_area_id` respectively (R-NOTE-002).
final class Note {
  Note({
    required this.id,
    required this.profileId,
    required this.lifeAreaId,
    required this.title,
    required this.body,
    required this.contentHash,
    required this.rank,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.pinned = false,
    this.archivedAtUtc,
    this.revision = 1,
    this.deletedAtUtc,
  }) {
    if (title.trim().isEmpty) {
      throw const FormatException('Note title must not be empty.');
    }
  }

  final NoteId id;
  final ProfileId profileId;
  final LifeAreaId lifeAreaId;

  /// Display title. Also the target of `[[wiki-link]]` resolution (R-NOTE-003).
  final String title;

  /// The canonical UTF-8 Markdown body — the single source of truth
  /// (R-NOTE-001).
  final String body;

  /// Deterministic content fingerprint over the canonical title+body.
  final String contentHash;

  /// Pinned notes surface first in list views (R-NOTE-002).
  final bool pinned;

  /// Archive instant, or null when the note is not archived (R-NOTE-002).
  final int? archivedAtUtc;

  /// Stable manual ordering rank.
  final NoteRank rank;

  /// Semantic revision incremented on each semantic row change (data-model §1);
  /// also the exact base revision the draft journal pins against (R-NOTE-005).
  final int revision;

  final int createdAtUtc;
  final int updatedAtUtc;
  final int? deletedAtUtc;

  bool get isArchived => archivedAtUtc != null;
  bool get isDeleted => deletedAtUtc != null;

  Note copyWith({
    String? title,
    String? body,
    String? contentHash,
    bool? pinned,
    Object? archivedAtUtc = _sentinel,
    NoteRank? rank,
    LifeAreaId? lifeAreaId,
    int? revision,
    int? updatedAtUtc,
    Object? deletedAtUtc = _sentinel,
  }) {
    return Note(
      id: id,
      profileId: profileId,
      lifeAreaId: lifeAreaId ?? this.lifeAreaId,
      title: title ?? this.title,
      body: body ?? this.body,
      contentHash: contentHash ?? this.contentHash,
      pinned: pinned ?? this.pinned,
      archivedAtUtc: archivedAtUtc == _sentinel
          ? this.archivedAtUtc
          : archivedAtUtc as int?,
      rank: rank ?? this.rank,
      revision: revision ?? this.revision,
      createdAtUtc: createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      deletedAtUtc: deletedAtUtc == _sentinel
          ? this.deletedAtUtc
          : deletedAtUtc as int?,
    );
  }

  /// Passed to [copyWith] for a clearable field to mean "leave unchanged".
  static const Object unchanged = _sentinel;

  static const Object _sentinel = Object();
}
