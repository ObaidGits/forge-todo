import 'package:forge/core/domain/id.dart';

/// An explicit optional value for partial updates.
///
/// The absence of an [Opt] (a `null` field) means "leave unchanged"; a present
/// `Opt(value)` sets the field. This distinguishes the two intents a plain
/// nullable field cannot.
final class Opt<T> {
  const Opt(this.value);
  final T value;
}

/// Input for creating a note (R-NOTE-001, R-NOTE-002).
final class CreateNoteInput {
  const CreateNoteInput({
    required this.lifeAreaId,
    required this.title,
    this.body = '',
    this.pinned = false,
    this.tagIds = const <String>[],
  });

  final LifeAreaId lifeAreaId;
  final String title;

  /// Canonical UTF-8 Markdown body (R-NOTE-001).
  final String body;
  final bool pinned;
  final List<String> tagIds;
}

/// Input for patching a note (R-NOTE-001, R-NOTE-002). A `null` field leaves the
/// value unchanged.
final class UpdateNoteInput {
  const UpdateNoteInput({this.title, this.body, this.lifeAreaId});

  final String? title;

  /// A new canonical Markdown body.
  final String? body;
  final LifeAreaId? lifeAreaId;

  bool get isEmpty => title == null && body == null && lifeAreaId == null;
}
