import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/areas/application/life_area_command_service.dart';
import 'package:forge/features/areas/application/life_area_commands.dart';

/// The active profile plus its default Life Area, resolved (or freshly seeded)
/// during bootstrap.
final class ProvisionedProfile {
  const ProvisionedProfile({
    required this.profileId,
    required this.defaultAreaId,
    required this.wasSeeded,
  });

  final ProfileId profileId;
  final LifeAreaId defaultAreaId;

  /// True when this run created the profile and default areas; false when an
  /// existing store was reused.
  final bool wasSeeded;
}

/// Seeds a brand-new encrypted store with exactly one active profile and the
/// seven canonical default Life Areas, or resolves the existing ones.
///
/// Provisioning is idempotent: it keys off whether an active profile already
/// exists in the (decrypted) store, so a crash between opening the store and
/// finishing the seed — or any second launch — never duplicates rows
/// (R-GEN-002). The default area is the first one (Career); a new classifiable
/// aggregate inherits it without a mandatory chooser.
final class FirstRunProvisioning {
  const FirstRunProvisioning({
    required this.clock,
    required this.idGenerator,
    required this.areaCommands,
  });

  final Clock clock;
  final IdGenerator idGenerator;
  final LifeAreaCommandService areaCommands;

  /// The seven default Life Areas in canonical order. The first is the default.
  static const List<String> defaultLifeAreaNames = <String>[
    'Career',
    'Learning',
    'Health',
    'Finance',
    'Personal Growth',
    'Relationships',
    'Personal',
  ];

  /// Ensures the store has an active profile and default areas, binding the
  /// active profile id via [bindActiveProfile] before any command runs so the
  /// unit of work can peek the per-profile commit sequence.
  Future<ProvisionedProfile> ensure({
    required ForgeSchemaDatabase db,
    required void Function(String profileId) bindActiveProfile,
  }) async {
    final String? existingProfileId = await _activeProfileId(db);
    if (existingProfileId != null) {
      bindActiveProfile(existingProfileId);
      final String defaultAreaId = await _defaultAreaId(db, existingProfileId);
      return ProvisionedProfile(
        profileId: ProfileId(existingProfileId),
        defaultAreaId: LifeAreaId(defaultAreaId),
        wasSeeded: false,
      );
    }

    // Fresh store: create the single active profile row directly, then seed the
    // canonical Life Areas through the production command service so each is a
    // durable, receipted command (R-GEN-002, R-GEN-005).
    final String profileId = idGenerator.uuidV7();
    final int now = clock.utcNow().microsecondsSinceEpoch;
    await db.customStatement(
      'INSERT INTO profiles '
      '(id, display_name, locale, timezone_id, week_start, hour_format, '
      'is_active, created_at_utc, updated_at_utc) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        profileId,
        'You',
        'en',
        clock.timezoneId(),
        1,
        'h24',
        1,
        now,
        now,
      ],
    );
    bindActiveProfile(profileId);

    final ProfileId typedProfileId = ProfileId(profileId);
    String? defaultAreaId;
    for (int i = 0; i < defaultLifeAreaNames.length; i++) {
      final String name = defaultLifeAreaNames[i];
      final Result<CommittedCommandResult> result = await areaCommands.create(
        commandId: CommandId(idGenerator.uuidV7()),
        profileId: typedProfileId,
        input: CreateLifeAreaInput(name: name, makeDefault: i == 0),
      );
      final CommittedCommandResult committed = switch (result) {
        Success<CommittedCommandResult>(:final CommittedCommandResult value) =>
          value,
        Failed<CommittedCommandResult>(:final Failure failure) =>
          throw StateError(
            'Failed to seed default Life Area "$name": ${failure.code}.',
          ),
      };
      if (i == 0) {
        defaultAreaId =
            (jsonDecode(committed.resultPayload!) as Map<String, Object?>)['id']
                as String;
      }
    }

    return ProvisionedProfile(
      profileId: typedProfileId,
      defaultAreaId: LifeAreaId(defaultAreaId!),
      wasSeeded: true,
    );
  }

  Future<String?> _activeProfileId(ForgeSchemaDatabase db) async {
    final List<QueryRow> rows = await db
        .customSelect('SELECT id FROM profiles WHERE is_active = 1 LIMIT 1')
        .get();
    return rows.isEmpty ? null : rows.first.read<String>('id');
  }

  Future<String> _defaultAreaId(
    ForgeSchemaDatabase db,
    String profileId,
  ) async {
    // Prefer the explicit default; fall back to the lowest-ranked live area so
    // quick capture always has an inheritable area even if a prior run left no
    // default flag (defensive; the seed always sets one).
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT id FROM life_areas '
          'WHERE profile_id = ? AND deleted_at_utc IS NULL '
          'ORDER BY is_default DESC, rank ASC LIMIT 1',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    if (rows.isEmpty) {
      throw StateError('Active profile has no Life Area to inherit.');
    }
    return rows.first.read<String>('id');
  }
}
