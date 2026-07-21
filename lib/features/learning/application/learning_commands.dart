import 'package:forge/features/learning/domain/learning_item_type.dart';
import 'package:forge/features/learning/domain/learning_progress_mode.dart';
import 'package:forge/features/learning/domain/learning_resource_status.dart';
import 'package:forge/features/learning/domain/learning_resource_type.dart';

/// A tri-state field edit: leave unchanged, clear to null, or set a value.
final class FieldEdit<T> {
  /// Leave the existing value unchanged.
  const FieldEdit.unchanged() : _kind = _EditKind.unchanged, value = null;

  /// Clear the value to null.
  const FieldEdit.clear() : _kind = _EditKind.clear, value = null;

  /// Set the value to [value].
  const FieldEdit.set(this.value) : _kind = _EditKind.set;

  final _EditKind _kind;
  final T? value;

  bool get isUnchanged => _kind == _EditKind.unchanged;
  bool get isClear => _kind == _EditKind.clear;
  bool get isSet => _kind == _EditKind.set;
}

enum _EditKind { unchanged, clear, set }

/// Input to create a Learning Resource (R-LEARN-001).
final class CreateResourceInput {
  const CreateResourceInput({
    required this.lifeAreaId,
    required this.title,
    required this.type,
    this.sourceUri,
    this.creator,
    this.noteId,
    this.status = LearningResourceStatus.active,
    this.progressMode = LearningProgressMode.derived,
    this.manualProgressPermille,
  });

  final String lifeAreaId;
  final String title;
  final LearningResourceType type;
  final String? sourceUri;
  final String? creator;
  final String? noteId;
  final LearningResourceStatus status;
  final LearningProgressMode progressMode;
  final int? manualProgressPermille;
}

/// Input to update a Learning Resource. Unspecified fields are left unchanged;
/// nullable fields use [FieldEdit] to distinguish clear from unchanged.
final class UpdateResourceInput {
  const UpdateResourceInput({
    required this.resourceId,
    this.title,
    this.type,
    this.status,
    this.progressMode,
    FieldEdit<String>? sourceUri,
    FieldEdit<String>? creator,
    FieldEdit<String>? noteId,
    FieldEdit<int>? manualProgressPermille,
  }) : sourceUri = sourceUri ?? const FieldEdit<String>.unchanged(),
       creator = creator ?? const FieldEdit<String>.unchanged(),
       noteId = noteId ?? const FieldEdit<String>.unchanged(),
       manualProgressPermille =
           manualProgressPermille ?? const FieldEdit<int>.unchanged();

  final String resourceId;
  final String? title;
  final LearningResourceType? type;
  final LearningResourceStatus? status;
  final LearningProgressMode? progressMode;
  final FieldEdit<String> sourceUri;
  final FieldEdit<String> creator;
  final FieldEdit<String> noteId;
  final FieldEdit<int> manualProgressPermille;
}

/// Input to add an ordered item to a Learning Resource (R-LEARN-001).
final class AddItemInput {
  const AddItemInput({
    required this.resourceId,
    required this.title,
    required this.type,
    this.parentId,
    this.sourceUri,
    this.durationSec,
  });

  final String resourceId;
  final String title;
  final LearningItemType type;
  final String? parentId;
  final String? sourceUri;
  final int? durationSec;
}

/// Input to update an item's fields (R-LEARN-001).
final class UpdateItemInput {
  const UpdateItemInput({
    required this.itemId,
    this.title,
    this.type,
    FieldEdit<String>? sourceUri,
    FieldEdit<int>? durationSec,
  }) : sourceUri = sourceUri ?? const FieldEdit<String>.unchanged(),
       durationSec = durationSec ?? const FieldEdit<int>.unchanged();

  final String itemId;
  final String? title;
  final LearningItemType? type;
  final FieldEdit<String> sourceUri;
  final FieldEdit<int> durationSec;
}

/// Input to move an item to a new rank position between two neighbours
/// (R-LEARN-001 ordering).
final class MoveItemInput {
  const MoveItemInput({
    required this.itemId,
    this.afterItemId,
    this.beforeItemId,
  });

  final String itemId;

  /// The item immediately before the target position, or null for the start.
  final String? afterItemId;

  /// The item immediately after the target position, or null for the end.
  final String? beforeItemId;
}

/// Input to log a new study session (R-LEARN-002).
final class LogStudySessionInput {
  const LogStudySessionInput({
    required this.resourceId,
    required this.startedAtUtc,
    required this.endedAtUtc,
    this.itemId,
    this.focusSessionId,
    this.note,
  });

  final String resourceId;

  /// Session start/end as integer UTC microseconds; duration is derived.
  final int startedAtUtc;
  final int endedAtUtc;
  final String? itemId;
  final String? focusSessionId;
  final String? note;
}

/// Input to correct a study session by appending a superseding version
/// (R-LEARN-002 immutable lifecycle).
final class CorrectStudySessionInput {
  const CorrectStudySessionInput({
    required this.logicalId,
    this.startedAtUtc,
    this.endedAtUtc,
    FieldEdit<String>? itemId,
    FieldEdit<String>? focusSessionId,
    FieldEdit<String>? note,
    this.reason,
  }) : itemId = itemId ?? const FieldEdit<String>.unchanged(),
       focusSessionId = focusSessionId ?? const FieldEdit<String>.unchanged(),
       note = note ?? const FieldEdit<String>.unchanged();

  final String logicalId;
  final int? startedAtUtc;
  final int? endedAtUtc;
  final FieldEdit<String> itemId;
  final FieldEdit<String> focusSessionId;
  final FieldEdit<String> note;
  final String? reason;
}
