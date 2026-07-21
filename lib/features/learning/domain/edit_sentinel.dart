/// Shared sentinel distinguishing "leave unchanged" from an explicit null clear
/// in `copyWith` calls on learning aggregates.
///
/// A single shared instance lets the application layer resolve a tri-state edit
/// once and pass the result to either a [LearningResource] or [LearningItem]
/// copyWith without coupling to an entity-specific sentinel.
const Object keepEdit = Object();
