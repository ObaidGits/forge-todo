enum FailureKind {
  validation,
  permission,
  storage,
  network,
  conflict,
  unavailableCapability,
  maintenanceLocked,
  unexpected,
}

/// Stable, presentation-safe failure returned by application boundaries.
final class Failure {
  const Failure({
    required this.kind,
    required this.code,
    required this.safeMessageKey,
    required this.retryable,
    this.redactedCause,
  });

  final FailureKind kind;
  final String code;
  final String safeMessageKey;
  final bool retryable;
  final String? redactedCause;
}

sealed class Result<T> {
  const Result();

  R fold<R>({
    required R Function(T value) success,
    required R Function(Failure failure) failure,
  });

  T? get valueOrNull => switch (this) {
    Success<T>(value: final T value) => value,
    Failed<T>() => null,
  };

  Failure? get failureOrNull => switch (this) {
    Success<T>() => null,
    Failed<T>(failure: final Failure failure) => failure,
  };
}

final class Success<T> extends Result<T> {
  const Success(this.value);

  final T value;

  @override
  R fold<R>({
    required R Function(T value) success,
    required R Function(Failure failure) failure,
  }) => success(value);
}

final class Failed<T> extends Result<T> {
  const Failed(this.failure);

  final Failure failure;

  @override
  R fold<R>({
    required R Function(T value) success,
    required R Function(Failure failure) failure,
  }) => failure(this.failure);
}
