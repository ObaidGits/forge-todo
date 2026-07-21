import 'dart:collection';

enum TransportFailureKind {
  timeout,
  tls,
  authentication,
  rateLimited,
  server,
  connectionLostBeforeCommit,
  connectionLostAfterCommit,
  malformedResponse,
}

final class TransportFailure implements Exception {
  const TransportFailure(this.kind, [this.message = '']);

  final TransportFailureKind kind;
  final String message;

  @override
  String toString() => 'TransportFailure(${kind.name}, $message)';
}

sealed class TransportStep<T extends Object> {
  const TransportStep();

  const factory TransportStep.response(T value) = TransportResponse<T>;
  const factory TransportStep.failure(TransportFailure failure) =
      TransportError<T>;
}

final class TransportResponse<T extends Object> extends TransportStep<T> {
  const TransportResponse(this.value);

  final T value;
}

final class TransportError<T extends Object> extends TransportStep<T> {
  const TransportError(this.failure);

  final TransportFailure failure;
}

final class FakeTransport<Request extends Object, Response extends Object> {
  FakeTransport([Iterable<TransportStep<Response>> script = const <Never>[]])
    : _steps = Queue<TransportStep<Response>>.of(script);

  final Queue<TransportStep<Response>> _steps;
  final List<Request> _requests = <Request>[];

  List<Request> get requests => List<Request>.unmodifiable(_requests);

  int get pendingStepCount => _steps.length;

  void enqueue(TransportStep<Response> step) {
    _steps.add(step);
  }

  Future<Response> send(Request request) async {
    _requests.add(request);
    if (_steps.isEmpty) {
      throw StateError('Transport script exhausted.');
    }
    final TransportStep<Response> step = _steps.removeFirst();
    return switch (step) {
      TransportResponse<Response>(:final Response value) => value,
      TransportError<Response>(:final TransportFailure failure) =>
        throw failure,
    };
  }

  void verifyExhausted() {
    if (_steps.isNotEmpty) {
      throw StateError('${_steps.length} scripted transport steps remain.');
    }
  }
}
