import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/schema/ownership_classification.dart';

import 'schema_test_database.dart';

/// R-GEN-002: the data dictionary SHALL classify every table, and area-free
/// operational rows MUST still be profile-owned unless they are database-global
/// singletons/registries.
///
/// **Validates: Requirements R-GEN-002**
void main() {
  late ForgeSchemaDatabase db;

  setUp(() {
    db = openSchemaDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  group('given the core schema when classifying tables', () {
    test('then every present table has exactly one ownership class', () {
      for (final TableInfo<Table, dynamic> table in db.allTables) {
        final String name = table.actualTableName;
        expect(
          ownershipClassFor(name),
          isNotNull,
          reason: 'Table "$name" is missing an ownership classification.',
        );
      }
    });

    test('then no classification names a table that does not exist', () {
      final Set<String> present = db.allTables
          .map((TableInfo<Table, dynamic> t) => t.actualTableName)
          .toSet();
      for (final String classified in forgeTableOwnership.keys) {
        expect(
          present,
          contains(classified),
          reason: 'Classified table "$classified" is not in the schema.',
        );
      }
    });

    test('then exactly one installation-root table exists', () {
      final Iterable<String> roots = forgeTableOwnership.entries
          .where(
            (MapEntry<String, OwnershipClass> e) =>
                e.value == OwnershipClass.installationRoot,
          )
          .map((MapEntry<String, OwnershipClass> e) => e.key);
      expect(roots, <String>['profiles']);
    });

    test('then every non-exempt table carries a profile_id column', () {
      for (final TableInfo<Table, dynamic> table in db.allTables) {
        final String name = table.actualTableName;
        final bool exempt =
            profileExemptTables.contains(name) ||
            ownershipClassFor(name) == OwnershipClass.installationRoot;
        if (exempt) {
          continue;
        }
        // Most tables own by `profile_id`; the sync link row keys ownership on
        // the existing local profile via `local_profile_id` (R-SYNC-001).
        final bool hasProfileId = table.$columns.any(
          (GeneratedColumn<Object> c) =>
              c.name == 'profile_id' || c.name == 'local_profile_id',
        );
        expect(
          hasProfileId,
          isTrue,
          reason: 'Area-free table "$name" must be profile-owned.',
        );
      }
    });
  });
}
