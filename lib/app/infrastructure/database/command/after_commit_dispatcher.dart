import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/security/redacting_log.dart';

/// An idempotent after-commit handler (design.md §5).
///
/// Handlers receive only the IDs-carrying [AfterCommitHint]. They may trigger
/// reminder/widget work, cache notification, or projection verification, but
/// MUST NOT perform authoritative FTS/outbox/content writes and MUST be safe to
/// invoke more than once for the same hint.
abstract interface class AfterCommitHandler {
  /// Hint kinds this handler reacts to.
  Set<String> get kinds;

  Future<void> handle(AfterCommitHint hint);
}

/// Dispatches volatile after-commit hints to registered handlers.
///
/// Dispatch happens strictly after the originating transaction has committed,
/// so a hint is never observed for an uncommitted change. Because hints are
/// acceleration only, a handler failure is logged and swallowed: durable dirty
/// markers written inside the transaction remain the source of truth and are
/// reconciled on startup/resume.
final class AfterCommitDispatcher {
  AfterCommitDispatcher({
    List<AfterCommitHandler> handlers = const <AfterCommitHandler>[],
    this._logger,
  }) : _handlers = List<AfterCommitHandler>.of(handlers);

  final List<AfterCommitHandler> _handlers;
  final StructuredLogger? _logger;

  static const String _component = 'database.after_commit';

  void register(AfterCommitHandler handler) => _handlers.add(handler);

  /// Dispatches [hints] to every matching handler. Duplicate hints are
  /// collapsed so re-dispatch stays idempotent.
  Future<void> dispatch(Iterable<AfterCommitHint> hints) async {
    final Set<AfterCommitHint> unique = <AfterCommitHint>{...hints};
    for (final AfterCommitHint hint in unique) {
      for (final AfterCommitHandler handler in _handlers) {
        if (!handler.kinds.contains(hint.kind)) {
          continue;
        }
        try {
          await handler.handle(hint);
        } on Object catch (error) {
          _logger?.log(
            level: LogLevel.warning,
            component: _component,
            eventCode: 'hint_handler_failed',
            attributes: <String, LogAttribute>{
              'kind': LogAttribute.operational(hint.kind),
              'entity_type': LogAttribute.operational(hint.entityType),
              'error': LogAttribute.operational(error.runtimeType.toString()),
            },
          );
        }
      }
    }
  }
}
