import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/id.dart';

void main() {
  test('database generation keeps typed identity and schema version', () {
    final DatabaseGeneration generation = DatabaseGeneration(
      id: GenerationId('generation_01'),
      schemaVersion: 7,
    );

    expect(generation.id, GenerationId('generation_01'));
    expect(generation.schemaVersion, 7);
  });

  test('runtime and write-origin contracts expose every lifecycle state', () {
    expect(DatabaseRuntimeState.values, hasLength(7));
    expect(
      WriteOrigin.values,
      containsAll(<WriteOrigin>[
        WriteOrigin.localCommand,
        WriteOrigin.remoteApply,
        WriteOrigin.bootstrapRebase,
        WriteOrigin.restore,
        WriteOrigin.migration,
      ]),
    );
  });
}
