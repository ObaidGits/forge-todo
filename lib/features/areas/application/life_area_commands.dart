/// Typed command inputs for Life Area management (R-GEN-002).
///
/// Each input is a small immutable value validated at the domain boundary; the
/// command service turns it into one atomic durable command.
library;

/// Input for creating a new Life Area (R-GEN-002 "users MAY ... add areas").
final class CreateLifeAreaInput {
  const CreateLifeAreaInput({required this.name, this.makeDefault = false});

  final String name;

  /// When true the new area becomes the profile's single default area, which a
  /// new classifiable aggregate inherits without a mandatory chooser.
  final bool makeDefault;
}

/// Input for renaming an existing Life Area (R-GEN-002 "users MAY rename").
final class RenameLifeAreaInput {
  const RenameLifeAreaInput({required this.name});

  final String name;
}

/// Input for reordering a Life Area between two neighbours (R-GEN-002 "users
/// MAY ... reorder").
///
/// [beforeRank]/[afterRank] are the lexical ranks of the immediate neighbours
/// at the drop position; a null bound means the open end of the ordering.
final class ReorderLifeAreaInput {
  const ReorderLifeAreaInput({this.beforeRank, this.afterRank});

  final String? beforeRank;
  final String? afterRank;
}
