import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/result.dart';

void main() {
  test('success exposes and folds its committed value', () {
    const Result<int> result = Success<int>(42);

    expect(result.valueOrNull, 42);
    expect(result.failureOrNull, isNull);
    expect(
      result.fold<String>(
        success: (int value) => 'value:$value',
        failure: (Failure failure) => failure.code,
      ),
      'value:42',
    );
  });

  test('failure preserves the stable classified error contract', () {
    const Failure failure = Failure(
      kind: FailureKind.storage,
      code: 'db.write_failed',
      safeMessageKey: 'errors.storage.writeFailed',
      retryable: true,
      redactedCause: 'sqlite-error-redacted',
    );
    const Result<int> result = Failed<int>(failure);

    expect(result.valueOrNull, isNull);
    expect(result.failureOrNull, same(failure));
    expect(
      result.fold<String>(
        success: (int value) => '$value',
        failure: (Failure value) => value.code,
      ),
      'db.write_failed',
    );
  });
}
