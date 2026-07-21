import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/backup/domain/human_readable_export.dart';
import 'package:forge/features/backup/infrastructure/human_readable_codecs.dart';

import '../../../helpers/helpers.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-BACKUP-HUMAN-CODEC-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('10.6'),
  requirements: <RequirementId>[RequirementId('R-BACKUP-005')],
);

ExportDocument _sampleDoc() => ExportDocument(
  createdAtUtcMicros: 1730000000000000,
  profileId: 'profile-1',
  tables: <ExportTable>[
    ExportTable(
      name: 'life_areas',
      columns: const <String>['id', 'name', 'rank'],
      rows: const <Map<String, String?>>[
        <String, String?>{'id': 'area-1', 'name': 'Health', 'rank': 'a0'},
        <String, String?>{'id': 'area-2', 'name': 'Career', 'rank': 'a1'},
      ],
    ),
    ExportTable(
      name: 'tasks',
      columns: const <String>['id', 'life_area_id', 'title', 'note_id'],
      rows: const <Map<String, String?>>[
        <String, String?>{
          'id': 'task-1',
          'life_area_id': 'area-1',
          'title': 'Run 5k',
          'note_id': null,
        },
      ],
    ),
  ],
);

void main() {
  group('human-readable codecs', () {
    for (final HumanReadableFormat format in HumanReadableFormat.values) {
      testWithEvidence(
        _evidence('ROUNDTRIP-${format.id.toUpperCase()}'),
        'a ${format.id} export decodes back to an equal document',
        () {
          final HumanReadableCodec codec = humanReadableCodec(format);
          final ExportDocument original = _sampleDoc();
          final List<int> bytes = codec.encode(original);
          final ExportDocument restored = codec.decode(bytes);
          expect(restored, original);
        },
      );

      testWithEvidence(
        _evidence('NOTICE-${format.id.toUpperCase()}'),
        'a ${format.id} export embeds the less-secure notice',
        () {
          final List<int> bytes = humanReadableCodec(
            format,
          ).encode(_sampleDoc());
          expect(utf8.decode(bytes), contains('less secure'));
        },
      );
    }

    testWithEvidence(
      _evidence('JSON-NULL'),
      'JSON round-trips null cells distinctly from empty strings',
      () {
        final ExportDocument doc = ExportDocument(
          createdAtUtcMicros: 1,
          profileId: null,
          tables: <ExportTable>[
            ExportTable(
              name: 'notes',
              columns: const <String>['id', 'body'],
              rows: const <Map<String, String?>>[
                <String, String?>{'id': 'n1', 'body': null},
                <String, String?>{'id': 'n2', 'body': ''},
              ],
            ),
          ],
        );
        final HumanReadableCodec codec = humanReadableCodec(
          HumanReadableFormat.json,
        );
        final ExportDocument restored = codec.decode(codec.encode(doc));
        expect(restored.table('notes')!.rows[0]['body'], isNull);
        expect(restored.table('notes')!.rows[1]['body'], '');
      },
    );

    testWithEvidence(
      _evidence('CSV-NULL'),
      'CSV round-trips null cells distinctly from empty strings',
      () {
        final ExportDocument doc = ExportDocument(
          createdAtUtcMicros: 1,
          profileId: null,
          tables: <ExportTable>[
            ExportTable(
              name: 'notes',
              columns: const <String>['id', 'body'],
              rows: const <Map<String, String?>>[
                <String, String?>{'id': 'n1', 'body': null},
                <String, String?>{'id': 'n2', 'body': ''},
              ],
            ),
          ],
        );
        final HumanReadableCodec codec = humanReadableCodec(
          HumanReadableFormat.csv,
        );
        final ExportDocument restored = codec.decode(codec.encode(doc));
        expect(restored.table('notes')!.rows[0]['body'], isNull);
        expect(restored.table('notes')!.rows[1]['body'], '');
      },
    );

    testWithEvidence(
      _evidence('CSV-QUOTING'),
      'CSV round-trips cells containing commas, quotes, and separators',
      () {
        final ExportDocument doc = ExportDocument(
          createdAtUtcMicros: 1,
          profileId: 'p',
          tables: <ExportTable>[
            ExportTable(
              name: 'tasks',
              columns: const <String>['id', 'title'],
              rows: const <Map<String, String?>>[
                <String, String?>{
                  'id': 't1',
                  'title': 'buy milk, eggs and "bread"',
                },
              ],
            ),
          ],
        );
        final HumanReadableCodec codec = humanReadableCodec(
          HumanReadableFormat.csv,
        );
        final ExportDocument restored = codec.decode(codec.encode(doc));
        expect(
          restored.table('tasks')!.rows[0]['title'],
          'buy milk, eggs and "bread"',
        );
      },
    );

    testWithEvidence(
      _evidence('MARKDOWN-PIPES'),
      'Markdown round-trips cells containing pipe characters',
      () {
        final ExportDocument doc = ExportDocument(
          createdAtUtcMicros: 1,
          profileId: 'p',
          tables: <ExportTable>[
            ExportTable(
              name: 'tasks',
              columns: const <String>['id', 'title'],
              rows: const <Map<String, String?>>[
                <String, String?>{'id': 't1', 'title': 'a | b | c'},
              ],
            ),
          ],
        );
        final HumanReadableCodec codec = humanReadableCodec(
          HumanReadableFormat.markdown,
        );
        final ExportDocument restored = codec.decode(codec.encode(doc));
        expect(restored.table('tasks')!.rows[0]['title'], 'a | b | c');
      },
    );

    testWithEvidence(
      _evidence('JSON-REJECT'),
      'a malformed JSON document is rejected fail-closed',
      () {
        final HumanReadableCodec codec = humanReadableCodec(
          HumanReadableFormat.json,
        );
        expect(
          () => codec.decode(utf8.encode('{ not json')),
          throwsA(isA<HumanReadableFormatException>()),
        );
      },
    );

    testWithEvidence(
      _evidence('GEN-ROUNDTRIP'),
      'randomly generated string documents round-trip through every format',
      () {
        final Random random = Random(20260706);
        for (int trial = 0; trial < 60; trial += 1) {
          final ExportDocument doc = _randomStringDoc(random, trial);
          for (final HumanReadableFormat format in HumanReadableFormat.values) {
            final HumanReadableCodec codec = humanReadableCodec(format);
            final ExportDocument restored = codec.decode(codec.encode(doc));
            expect(restored, doc, reason: 'format=${format.id} trial=$trial');
          }
        }
      },
    );
  });
}

/// Builds a document whose cells are non-empty, non-null strings so all three
/// formats (including Markdown, whose empty cell is ambiguous) round-trip.
ExportDocument _randomStringDoc(Random random, int trial) {
  const List<String> tableNames = <String>['tasks', 'notes', 'goals'];
  final int tableCount = 1 + random.nextInt(3);
  final List<ExportTable> tables = <ExportTable>[];
  for (int t = 0; t < tableCount; t += 1) {
    final int columnCount = 2 + random.nextInt(3);
    final List<String> columns = <String>[
      'id',
      for (int c = 1; c < columnCount; c += 1) 'col_${c}_$t',
    ];
    final int rowCount = random.nextInt(4);
    final List<Map<String, String?>> rows = <Map<String, String?>>[];
    for (int r = 0; r < rowCount; r += 1) {
      rows.add(<String, String?>{
        for (final String column in columns) column: _randomWord(random),
      });
    }
    tables.add(
      ExportTable(
        name: '${tableNames[t]}_$trial',
        columns: columns,
        rows: rows,
      ),
    );
  }
  return ExportDocument(
    createdAtUtcMicros: random.nextInt(1 << 32),
    profileId: 'profile-${random.nextInt(1000)}',
    tables: tables,
  );
}

String _randomWord(Random random) {
  const String alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789 -';
  final int length = 1 + random.nextInt(10);
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < length; i += 1) {
    buffer.write(alphabet[random.nextInt(alphabet.length)]);
  }
  // Trim so a value never ends up as an ambiguous empty/whitespace cell.
  final String word = buffer.toString().trim();
  return word.isEmpty ? 'x' : word;
}
