import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/active_generation_pointer.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/id.dart';

import '../../../../helpers/helpers.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-DB-GENPOINTER-$suffix'),
  releaseTag: ReleaseTag.mvp,
  taskId: SpecTaskId('3.1'),
  requirements: <RequirementId>[RequirementId('R-GEN-001')],
);

void main() {
  late Directory dir;
  late ActiveGenerationPointer pointer;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('forge-gen-');
    pointer = ActiveGenerationPointer(
      pointerFile: File('${dir.path}/active_generation.json'),
    );
  });

  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  ActiveGenerationRecord record(String id, int schema, String name) =>
      ActiveGenerationRecord(
        generation: DatabaseGeneration(
          id: GenerationId(id),
          schemaVersion: schema,
        ),
        directoryName: name,
      );

  testWithEvidence(
    _evidence('001'),
    'read returns null when no pointer has been written',
    () async {
      expect(await pointer.read(), isNull);
    },
  );

  testWithEvidence(
    _evidence('002'),
    'switchTo then read round-trips the generation record',
    () async {
      await pointer.switchTo(record('gen-a', 1, 'generation-0001'));
      final ActiveGenerationRecord? read = await pointer.read();
      expect(read, isNotNull);
      expect(read!.generation.id.value, 'gen-a');
      expect(read.generation.schemaVersion, 1);
      expect(read.directoryName, 'generation-0001');
    },
  );

  testWithEvidence(
    _evidence('003'),
    'switchTo atomically replaces the previous pointer',
    () async {
      await pointer.switchTo(record('gen-a', 1, 'generation-0001'));
      await pointer.switchTo(record('gen-b', 2, 'generation-0002'));
      final ActiveGenerationRecord? read = await pointer.read();
      expect(read!.generation.id.value, 'gen-b');
      expect(read.directoryName, 'generation-0002');
    },
  );

  testWithEvidence(
    _evidence('004'),
    'a corrupt pointer surfaces a recovery signal rather than resetting data',
    () async {
      await File(
        '${dir.path}/active_generation.json',
      ).writeAsString('{ truncated');
      await expectLater(
        pointer.read,
        throwsA(isA<ActiveGenerationPointerCorrupt>()),
      );
    },
  );
}
