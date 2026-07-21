import 'package:forge/core/domain/id.dart';
import 'package:forge/features/goals/application/goal_commands.dart' show Opt;
import 'package:forge/features/goals/domain/roadmap_status.dart';
import 'package:forge/features/goals/domain/roadmap_topic_status.dart';

/// Input for creating a goal's roadmap (R-GOAL-001, R-GOAL-003).
final class CreateRoadmapInput {
  const CreateRoadmapInput({
    required this.title,
    this.status = RoadmapStatus.active,
    this.targetDate,
  });

  final String title;
  final RoadmapStatus status;
  final String? targetDate;
}

/// Input for patching a roadmap. A `null` field leaves the value unchanged;
/// wrap clearable fields in [Opt].
final class UpdateRoadmapInput {
  const UpdateRoadmapInput({this.title, this.status, this.targetDate});

  final String? title;
  final RoadmapStatus? status;
  final Opt<String?>? targetDate;

  bool get isEmpty => title == null && status == null && targetDate == null;
}

/// Input for creating a roadmap section (R-GOAL-003).
final class CreateSectionInput {
  const CreateSectionInput({required this.title});

  final String title;
}

/// Input for patching a section (R-GOAL-003).
final class UpdateSectionInput {
  const UpdateSectionInput({this.title});

  final String? title;

  bool get isEmpty => title == null;
}

/// Input for creating a roadmap topic (R-GOAL-003, R-GOAL-004).
///
/// A topic MAY carry a nonnegative completion [weight] (null normalizes to 1
/// for progress), an [estimateSec] estimate, an initial [status], and a
/// canonical [noteId] reference.
final class CreateTopicInput {
  const CreateTopicInput({
    required this.title,
    this.status = RoadmapTopicStatus.open,
    this.weight,
    this.estimateSec,
    this.noteId,
  });

  final String title;
  final RoadmapTopicStatus status;
  final num? weight;
  final int? estimateSec;
  final NoteId? noteId;
}

/// Input for patching a topic's descriptive fields (R-GOAL-003). A `null` field
/// leaves the value unchanged; wrap clearable fields in [Opt]. Status and
/// completion are changed through the dedicated status command.
final class UpdateTopicInput {
  const UpdateTopicInput({
    this.title,
    this.weight,
    this.estimateSec,
    this.noteId,
  });

  final String? title;
  final Opt<num?>? weight;
  final Opt<int?>? estimateSec;
  final Opt<NoteId?>? noteId;

  bool get isEmpty =>
      title == null && weight == null && estimateSec == null && noteId == null;
}

/// Input for creating a checklist item (R-GOAL-003).
final class CreateChecklistItemInput {
  const CreateChecklistItemInput({required this.text});

  final String text;
}

/// Input for patching a checklist item (R-GOAL-003).
final class UpdateChecklistItemInput {
  const UpdateChecklistItemInput({this.text});

  final String? text;

  bool get isEmpty => text == null;
}

/// Input for linking a topic to another domain entity (R-GOAL-003).
final class LinkTopicEntityInput {
  const LinkTopicEntityInput({
    required this.targetType,
    required this.targetId,
  });

  /// One of [RoadmapTopicTargetType] values (`task`, `note`,
  /// `learning_resource`).
  final String targetType;
  final String targetId;
}
