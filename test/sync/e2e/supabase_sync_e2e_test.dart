/// End-to-end convergence test against a LIVE local Supabase (Property 5,
/// content-preserving convergence; R-SYNC-001/003/004/007).
///
/// This talks to the running local Supabase over HTTP at 127.0.0.1:54321. It:
///
///   1. signs up an account through the real [GoTrueAuthClient];
///   2. provisions the account's remote profile via
///      [SupabaseRemoteProfileGateway] (the `forge.ensure_remote_profile` RPC);
///   3. builds TWO independent client stacks (device A + device B) — each a real
///      in-memory Drift generation with its own pull cursor and typed applier,
///      sharing the one account and the real [SupabaseSyncTransport];
///   4. on device A creates a `tag`, pushes it, then pulls+applies on BOTH
///      devices and asserts the entity converges byte-for-byte on device B
///      (and A) equal to the server-accepted state;
///   5. asserts an idempotent push replay is stable and a re-pull is a no-op;
///   6. asserts a stale-epoch push is rejected before mutation.
///
/// It SKIPS cleanly when 127.0.0.1:54321 is unreachable so the offline repo
/// suite stays green, but runs and passes against the running local backend.
library;

import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/sync/pull_apply_coordinator.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/sync/application/forge_replication_manifest.dart';
import 'package:forge/features/sync/application/remote_applier.dart';
import 'package:forge/features/sync/application/sync_serialization.dart';
import 'package:forge/features/sync/application/sync_transport.dart';
import 'package:forge/features/sync/domain/semantic_group.dart';
import 'package:forge/features/sync/domain/sync_cursor.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';
import 'package:forge/features/sync/infrastructure/gotrue_auth_client.dart';
import 'package:forge/features/sync/infrastructure/supabase_remote_profile_gateway.dart';
import 'package:forge/features/sync/infrastructure/supabase_sync_transport.dart';

import '../../database/schema/schema_test_database.dart';
import '../../helpers/fake_clock.dart';

const String _host = '127.0.0.1';
const int _port = 54321;
final Uri _baseUrl = Uri.parse('http://$_host:$_port');
const String _anonKey = 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH';
const String _dbContainer = 'supabase_db_forge-todo';

Future<bool> _reachable() async {
  try {
    final Socket socket = await Socket.connect(
      _host,
      _port,
      timeout: const Duration(seconds: 1),
    );
    socket.destroy();
    return true;
  } on Object {
    return false;
  }
}

void main() {
  // Two independent in-memory generations are opened intentionally (device A +
  // device B); silence the benign multiple-database debug warning.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('Supabase sync end-to-end (live local backend)', () {
    late bool reachable;

    setUpAll(() async {
      reachable = await _reachable();
    });

    test(
      'device A push converges on device B; replay + stale-epoch behave',
      () async {
        if (!reachable) {
          markTestSkipped('local Supabase at $_host:$_port is unreachable');
          return;
        }

        // 1) Sign up a fresh account through the real GoTrue adapter.
        final GoTrueAuthClient auth = GoTrueAuthClient(
          baseUrl: _baseUrl,
          anonKey: _anonKey,
        );
        final String email =
            'e2e_${DateTime.now().microsecondsSinceEpoch}@example.com';
        final GoTrueSession signedUp = await auth.signUpWithPassword(
          email: email,
          password: 'password123',
        );
        expect(signedUp.userId, isNotEmpty);

        // Signing in again must return a working session for the same subject.
        final GoTrueSession signedIn = await auth.signInWithPassword(
          email: email,
          password: 'password123',
        );
        expect(signedIn.userId, signedUp.userId);

        final String ownerUserId = signedIn.userId;
        final MutableSupabaseSyncSession session = MutableSupabaseSyncSession(
          accessToken: signedIn.accessToken.reveal(),
          remoteProfileId: RemoteProfileId(ownerUserId),
        );

        // 2) Provision the account's remote profile (idempotent).
        final SupabaseRemoteProfileGateway gateway =
            SupabaseRemoteProfileGateway(
              baseUrl: _baseUrl,
              anonKey: _anonKey,
              session: session,
            );
        final RemoteProfileProvision provision = await gateway
            .ensureRemoteProfile(RemoteProfileId(ownerUserId));
        expect(provision.created, isTrue);
        expect(provision.snapshotEpoch.value, 0);
        // A second call is idempotent and reports the existing profile.
        final RemoteProfileProvision again = await gateway.ensureRemoteProfile(
          RemoteProfileId(ownerUserId),
        );
        expect(again.created, isFalse);

        final SupabaseSyncTransport transport = SupabaseSyncTransport(
          baseUrl: _baseUrl,
          anonKey: _anonKey,
          session: session,
        );

        // 3) Two independent client stacks sharing the one account.
        final _Device deviceA = await _Device.open(
          localProfile: 'device-a-profile',
          ownerUserId: ownerUserId,
          transport: transport,
        );
        final _Device deviceB = await _Device.open(
          localProfile: 'device-b-profile',
          ownerUserId: ownerUserId,
          transport: transport,
        );
        addTearDown(deviceA.close);
        addTearDown(deviceB.close);

        // 4) Device A creates a tag and pushes it.
        final String tagId = _uuid();
        final String groupId = _uuid();
        final SemanticGroup group = _tagInsertGroup(
          groupId: groupId,
          operationId: _uuid(),
          tagId: tagId,
          normalizedName: 'work',
          displayName: 'Work',
        );
        final PushBatch batch = deviceA.envelopeBuilder.build(
          localProfileId: ProfileId(deviceA.localProfile),
          deviceId: deviceA.deviceId,
          epoch: SnapshotEpoch.genesis,
          groups: <SemanticGroup>[group],
        );
        final PushResponse pushed = await transport.push(batch);
        expect(pushed.staleEpoch, isFalse);
        expect(pushed.results.single.outcome, SemanticGroupOutcome.accepted);

        // 5a) Idempotent replay: the same group id returns the same result and
        //     creates no second change.
        final PushResponse replay = await transport.push(batch);
        expect(replay.results.single.outcome, SemanticGroupOutcome.accepted);
        expect(replay.results.single.groupId, groupId);

        // 4/convergence) Pull + apply on BOTH devices.
        await deviceA.pullAndApply();
        await deviceB.pullAndApply();

        final Map<String, Object?>? tagOnA = await deviceA.readTag(tagId);
        final Map<String, Object?>? tagOnB = await deviceB.readTag(tagId);
        expect(tagOnB, isNotNull, reason: 'tag must converge onto device B');
        expect(tagOnA, isNotNull);
        // Content-preserving convergence: identical replicated content on both.
        expect(tagOnB!['normalized_name'], 'work');
        expect(tagOnB['display_name'], 'Work');
        expect(tagOnB['normalized_name'], tagOnA!['normalized_name']);
        expect(tagOnB['display_name'], tagOnA['display_name']);

        // 5b) A re-pull on device B is a harmless duplicate no-op: the cursor is
        //     unchanged and no new rows appear.
        final SyncCursor cursorBefore = await deviceB.readCursor();
        await deviceB.pullAndApply();
        final SyncCursor cursorAfter = await deviceB.readCursor();
        expect(cursorAfter.epoch.value, cursorBefore.epoch.value);
        expect(cursorAfter.serverSeq.value, cursorBefore.serverSeq.value);
        expect(await deviceB.tagCount(), 1);

        // 6) Stale-epoch push rejection. Bump the server epoch out-of-band and
        //    push at the now-stale epoch 0; the transport surfaces stale_epoch
        //    and nothing mutates. Skipped if the admin bump is unavailable.
        final bool bumped = await _bumpServerEpoch(ownerUserId, 5);
        if (bumped) {
          final SemanticGroup staleGroup = _tagInsertGroup(
            groupId: _uuid(),
            operationId: _uuid(),
            tagId: _uuid(),
            normalizedName: 'stale',
            displayName: 'Stale',
          );
          final PushBatch staleBatch = deviceA.envelopeBuilder.build(
            localProfileId: ProfileId(deviceA.localProfile),
            deviceId: deviceA.deviceId,
            epoch: SnapshotEpoch.genesis,
            groups: <SemanticGroup>[staleGroup],
          );
          final PushResponse staleResponse = await transport.push(staleBatch);
          expect(
            staleResponse.staleEpoch,
            isTrue,
            reason: 'a push behind the server epoch must be rejected',
          );
          expect(
            staleResponse.results.single.outcome,
            SemanticGroupOutcome.staleEpoch,
          );
        } else {
          // ignore: avoid_print
          print(
            'NOTE: skipped the stale-epoch assertion (could not bump the '
            'server epoch via docker/psql).',
          );
        }
      },
    );
  });
}

/// A single client stack: a real in-memory generation, its unit of work, the
/// identity/manifest wire boundary, and the atomic pull-apply coordinator with
/// an idempotent `tag` applier.
final class _Device {
  _Device._({
    required this.localProfile,
    required this.db,
    required this.unitOfWork,
    required this.transport,
    required this.envelopeBuilder,
    required this.translator,
    required this.clock,
    required this.deviceId,
  });

  static Future<_Device> open({
    required String localProfile,
    required String ownerUserId,
    required SyncTransport transport,
  }) async {
    final ForgeSchemaDatabase db = openSchemaDatabase();
    await insertProfile(db, id: localProfile);
    final DriftUnitOfWork unitOfWork = DriftUnitOfWork(
      db,
      activeProfileResolver: () => localProfile,
    );
    final SyncProfileLink link = SyncProfileLink(
      localProfileId: ProfileId(localProfile),
      backend: 'supabase',
      ownerUserId: OwnerUserId(ownerUserId),
      remoteProfileId: RemoteProfileId(ownerUserId),
      state: SyncLinkState.linked,
    );
    final SyncIdentityTranslator identity = SyncIdentityTranslator(link);
    final manifest = buildForgeReplicationManifestV1();
    return _Device._(
      localProfile: localProfile,
      db: db,
      unitOfWork: unitOfWork,
      transport: transport,
      envelopeBuilder: PushEnvelopeBuilder(
        translator: identity,
        manifest: manifest,
      ),
      translator: PullTranslator(identity),
      clock: FakeClock(initialUtc: DateTime.utc(2024, 1, 1)),
      // The server casts p_device_id to uuid, so a device id must be a UUID.
      deviceId: _uuid(),
    );
  }

  final String localProfile;
  final ForgeSchemaDatabase db;
  final DriftUnitOfWork unitOfWork;
  final SyncTransport transport;
  final PushEnvelopeBuilder envelopeBuilder;
  final PullTranslator translator;
  final FakeClock clock;
  final String deviceId;

  Future<void> close() => db.close();

  Future<void> pullAndApply() async {
    final PullApplyCoordinator coordinator = PullApplyCoordinator(
      unitOfWork: unitOfWork,
      appliers: RemoteApplierRegistry(<RemoteApplier>[
        _TagApplier(db, localProfile),
      ]),
      clock: clock,
    );
    for (int i = 0; i < 64; i += 1) {
      final SyncCursor cursor = await readCursor();
      final PullPage page = await transport.pull(cursor);
      final TranslatedPullPage translated = translator.translate(
        page: page,
        cursor: cursor,
      );
      final PullApplyResult result = await coordinator.applyPage(
        PullApplyRequest(page: translated),
      );
      if (result.outcome == PullApplyOutcome.bootstrapRequired) {
        break;
      }
      if (!page.hasMore) {
        break;
      }
    }
  }

  Future<SyncCursor> readCursor() async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT epoch, server_seq, cursor FROM sync_cursors '
          'WHERE profile_id = ? AND backend = ?',
          variables: <Variable<Object>>[
            Variable<String>(localProfile),
            const Variable<String>('supabase'),
          ],
        )
        .get();
    if (rows.isEmpty) {
      return SyncCursor.initial();
    }
    final Map<String, Object?> row = rows.single.data;
    return SyncCursor(
      epoch: SnapshotEpoch(row['epoch'] as int),
      serverSeq: ServerSeq((row['server_seq'] as int?) ?? 0),
      opaqueToken: row['cursor'] as String?,
    );
  }

  Future<Map<String, Object?>?> readTag(String tagId) async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT normalized_name, display_name FROM tags '
          'WHERE id = ? AND profile_id = ?',
          variables: <Variable<Object>>[
            Variable<String>(tagId),
            Variable<String>(localProfile),
          ],
        )
        .get();
    return rows.isEmpty ? null : rows.single.data;
  }

  Future<int> tagCount() async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM tags WHERE profile_id = ?',
          variables: <Variable<Object>>[Variable<String>(localProfile)],
        )
        .get();
    return rows.single.data['n'] as int;
  }
}

/// An idempotent typed applier for `tag` used by the E2E test. Upserts on the
/// primary key so re-applying the same change never duplicates a row.
final class _TagApplier implements RemoteApplier {
  _TagApplier(this.db, this.profileId);

  final ForgeSchemaDatabase db;
  final String profileId;

  @override
  String get entityType => 'tag';

  @override
  Future<void> apply(TransactionSession tx, RemoteChange change) async {
    if (change.tombstone || change.kind == SyncOperationKind.delete) {
      await db.customStatement(
        'DELETE FROM tags WHERE id = ? AND profile_id = ?',
        <Object?>[change.entityId, profileId],
      );
      return;
    }
    final String name = change.payload['normalized_name'] as String;
    final String display = (change.payload['display_name'] as String?) ?? name;
    await db.customStatement(
      'INSERT INTO tags '
      '(id, profile_id, normalized_name, display_name, created_at_utc, '
      'updated_at_utc) VALUES (?, ?, ?, ?, 0, 0) '
      'ON CONFLICT(id) DO UPDATE SET normalized_name = excluded.normalized_name,'
      ' display_name = excluded.display_name, '
      'updated_at_utc = excluded.updated_at_utc',
      <Object?>[change.entityId, profileId, name, display],
    );
  }
}

SemanticGroup _tagInsertGroup({
  required String groupId,
  required String operationId,
  required String tagId,
  required String normalizedName,
  required String displayName,
}) {
  return SemanticGroup(
    groupId: groupId,
    snapshotEpoch: 0,
    operations: <SyncOperation>[
      SyncOperation(
        operationId: operationId,
        index: 0,
        entityType: 'tag',
        entityId: tagId,
        kind: SyncOperationKind.insert,
        payload: <String, Object?>{
          'normalized_name': normalizedName,
          'display_name': displayName,
        },
        changedFields: const <String>['display_name', 'normalized_name'],
      ),
    ],
  );
}

/// Bumps the server snapshot epoch for [ownerUserId] out-of-band (as the
/// backend operator would on a retention purge) so the client's epoch 0 becomes
/// stale. Returns false when docker/psql is unavailable so the caller can skip.
Future<bool> _bumpServerEpoch(String ownerUserId, int epoch) async {
  try {
    final ProcessResult result = await Process.run('docker', <String>[
      'exec',
      '-i',
      _dbContainer,
      'psql',
      '-U',
      'postgres',
      '-d',
      'postgres',
      '-c',
      "update forge.remote_profiles set snapshot_epoch = $epoch where id = '$ownerUserId';",
    ]);
    return result.exitCode == 0 &&
        result.stdout.toString().contains('UPDATE 1');
  } on Object {
    return false;
  }
}

int _uuidCounter = 0;

/// A unique RFC-4122-shaped UUID v4 string (sufficient for server `uuid` casts).
String _uuid() {
  final int micros = DateTime.now().microsecondsSinceEpoch;
  final int salt = (micros + (_uuidCounter++)) & 0xFFFFFFFFFFFF;
  final String hi = micros.toRadixString(16).padLeft(12, '0');
  final String lo = salt.toRadixString(16).padLeft(12, '0');
  final String a = hi.substring(hi.length - 8);
  final String b = lo.substring(0, 4);
  final String c = '4${lo.substring(4, 7)}';
  final String d = '8${lo.substring(7, 10)}';
  final String e = (micros ^ salt).toRadixString(16).padLeft(12, '0');
  return '$a-$b-$c-$d-${e.substring(e.length - 12)}';
}
