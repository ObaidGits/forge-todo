/// Property 5 — Content-preserving convergence.
///
/// A generated multi-device model (2–5 devices) exchanges randomly interleaved
/// local edits, pushes, pulls, deletes, concurrent same-field/disjoint-field
/// edits, note-body edits, and stale-epoch bootstraps over the *real* domain
/// conflict policies ([EntityConflictPolicy], [mergeNoteBody]),
/// [ConflictArtifact], and the protocol authority types ([SnapshotEpoch],
/// [ServerSeq], [FieldVersionMap]). No network and no wall clock: the whole
/// system is driven deterministically from a seed so any counterexample is
/// reproducible and shrinkable by narrowing the seed range.
///
/// The property proves three things across every generated scenario, after all
/// devices quiesce (push everything, then pull to head until fixpoint):
///
///   1. **Eventual convergence** — every device reaches the identical converged
///      visible state, equal to the server-accepted state.
///   2. **Stale-epoch resurrection prevention** — a device holding a stale
///      epoch can never resurrect a tombstoned/retired entity; bootstrap
///      rebases its pending intents so a purged entity stays dead everywhere.
///   3. **Recoverability of every losing meaningful value** — for every
///      conflict where a value loses the visible state (same-field contention,
///      an un-mergeable note body, or a delete-vs-update), that losing value is
///      preserved in a durable, pullable conflict artifact that every device
///      holds intact. Nothing meaningful is ever silently lost.
///
/// The model is intentionally an authority reimplementation *only* for
/// sequencing/epoch/feed bookkeeping; every conflict *decision* delegates to the
/// production domain policies so this test exercises the real convergence and
/// preservation logic. Atomicity of one applied pull page is proven separately
/// by Property 4 (task 9.7).
///
/// **Property 5: Content-preserving convergence**
/// **Validates: Requirements R-SYNC-004, R-SYNC-006, NFR-REL-003**
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/conflict/conflict_artifact.dart';
import 'package:forge/features/sync/domain/conflict/entity_conflict_policy.dart';
import 'package:forge/features/sync/domain/conflict/note_body_merge.dart';

import '../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-CONVERGE-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.8'),
  requirements: <RequirementId>[
    RequirementId('R-SYNC-004'),
    RequirementId('R-SYNC-006'),
    RequirementId('NFR-REL-003'),
  ],
);

// The fixed scalar entity fields exercised by the model.
const List<String> _scalarFields = <String>['a', 'b', 'c'];

// A note body starts as three lines so devices can edit disjoint or identical
// line regions to drive clean merges vs. conflict copies.
const String _initialBody = 'line-0\nline-1\nline-2\n';

void main() {
  group('given a generated 2–5 device model over the real conflict policies', () {
    testWithEvidence(
      _evidence('PROP-001'),
      'after quiescence every device converges to the identical server-accepted '
      'state, no stale-epoch push resurrects a purged tombstone, and every '
      'losing meaningful value survives in a durable pullable artifact',
      () {
        const int caseCount = 300;
        int totalArtifacts = 0;
        int totalPurged = 0;
        int totalStaleRejections = 0;
        for (int seed = 0; seed < caseCount; seed += 1) {
          final _RunStats stats = _runScenario(seed);
          totalArtifacts += stats.artifacts;
          totalPurged += stats.purged;
          totalStaleRejections += stats.staleRejections;
        }
        // The property is only meaningful if the generated scenarios actually
        // exercised contention, retention/purge, and stale-epoch rejection.
        expect(
          totalArtifacts,
          greaterThan(0),
          reason: 'no scenario produced a losing value; property is vacuous',
        );
        expect(
          totalPurged,
          greaterThan(0),
          reason: 'no scenario purged a tombstone; resurrection path untested',
        );
        expect(
          totalStaleRejections,
          greaterThan(0),
          reason: 'no scenario forced a stale-epoch bootstrap',
        );
      },
    );
  });

  group('Content-preserving convergence examples', () {
    testWithEvidence(
      _evidence('DISJOINT-FIELDS-BOTH-SURVIVE'),
      'concurrent disjoint-field edits on two devices both survive and converge '
      'with no conflict artifact',
      () {
        final _Server server = _Server();
        final _Device d1 = _Device(1)..adopt(server);
        final _Device d2 = _Device(2)..adopt(server);

        // Seed a shared scalar entity.
        d1.insertScalar('k0');
        _quiesce(server, <_Device>[d1, d2]);

        // d1 edits field a; d2 edits field b — disjoint.
        d1.editScalar('k0', <String, int>{'a': 11});
        d2.editScalar('k0', <String, int>{'b': 22});
        _quiesce(server, <_Device>[d1, d2]);

        expect(
          server.artifacts,
          isEmpty,
          reason: 'disjoint edits never conflict',
        );
        expect(server.entities['k0']!.values['a'], 11);
        expect(server.entities['k0']!.values['b'], 22);
        _expectConverged(server, <_Device>[d1, d2]);
      },
    );

    testWithEvidence(
      _evidence('SAME-FIELD-LOSER-RECOVERABLE'),
      'concurrent same-field edits resolve to a single visible value while the '
      'losing value is preserved in a durable artifact on every device',
      () {
        final _Server server = _Server();
        final _Device d1 = _Device(1)..adopt(server);
        final _Device d2 = _Device(2)..adopt(server);

        d1.insertScalar('k0');
        _quiesce(server, <_Device>[d1, d2]);

        // Both devices edit field a from the same base, then d1 pushes first.
        d1.editScalar('k0', <String, int>{'a': 100});
        d2.editScalar('k0', <String, int>{'a': 200});
        d1.push(server);
        d2.push(server); // loses field a; its value must be preserved

        _quiesce(server, <_Device>[d1, d2]);

        expect(server.artifacts, hasLength(1));
        final ConflictArtifact artifact = server.artifacts.values.single;
        expect(artifact.policy, ConflictPolicyKind.sameFieldLaterServerWins);
        expect(artifact.localSnapshot!['a'], 200, reason: 'loser preserved');
        expect(artifact.remoteSnapshot!['a'], 100, reason: 'winner recorded');
        // Every device holds the artifact with the losing value intact.
        for (final _Device d in <_Device>[d1, d2]) {
          expect(d.artifacts.containsKey(artifact.remoteArtifactId), isTrue);
          expect(
            d.artifacts[artifact.remoteArtifactId]!.localSnapshot!['a'],
            200,
          );
        }
        _expectConverged(server, <_Device>[d1, d2]);
      },
    );

    testWithEvidence(
      _evidence('NOTE-CONFLICT-COPY-BOTH-BODIES'),
      'concurrent overlapping note edits keep one visible body and preserve the '
      'losing body in a durable conflict-copy artifact',
      () {
        final _Server server = _Server();
        final _Device d1 = _Device(1)..adopt(server);
        final _Device d2 = _Device(2)..adopt(server);

        d1.insertNote('n0');
        _quiesce(server, <_Device>[d1, d2]);

        // Both edit the SAME line differently -> overlapping -> conflict copy.
        d1.editNoteLine('n0', 1, 'd1-line-1');
        d2.editNoteLine('n0', 1, 'd2-line-1');
        d1.push(server);
        d2.push(server);

        _quiesce(server, <_Device>[d1, d2]);

        final List<ConflictArtifact> notes = server.artifacts.values
            .where(
              (ConflictArtifact a) =>
                  a.policy == ConflictPolicyKind.noteConflictCopy,
            )
            .toList();
        expect(notes, hasLength(1));
        expect(notes.single.localSnapshot!['body'], contains('d2-line-1'));
        expect(notes.single.remoteSnapshot!['body'], contains('d1-line-1'));
        _expectConverged(server, <_Device>[d1, d2]);
      },
    );

    testWithEvidence(
      _evidence('CLEAN-NOTE-MERGE'),
      'concurrent disjoint note-line edits three-way merge with no conflict',
      () {
        final _Server server = _Server();
        final _Device d1 = _Device(1)..adopt(server);
        final _Device d2 = _Device(2)..adopt(server);

        d1.insertNote('n0');
        _quiesce(server, <_Device>[d1, d2]);

        d1.editNoteLine('n0', 0, 'd1-line-0');
        d2.editNoteLine('n0', 2, 'd2-line-2');
        _quiesce(server, <_Device>[d1, d2]);

        expect(
          server.artifacts.values.where(
            (ConflictArtifact a) =>
                a.policy == ConflictPolicyKind.noteConflictCopy,
          ),
          isEmpty,
          reason: 'disjoint line edits merge cleanly',
        );
        final String body = server.entities['n0']!.values['body']! as String;
        expect(body, contains('d1-line-0'));
        expect(body, contains('d2-line-2'));
        _expectConverged(server, <_Device>[d1, d2]);
      },
    );

    testWithEvidence(
      _evidence('TOMBSTONE-WINS-UPDATE-PRESERVED'),
      'a delete concurrent with an update tombstones the visible state and '
      'preserves the losing update in a durable artifact',
      () {
        final _Server server = _Server();
        final _Device d1 = _Device(1)..adopt(server);
        final _Device d2 = _Device(2)..adopt(server);

        d1.insertScalar('k0');
        _quiesce(server, <_Device>[d1, d2]);

        // d1 deletes; d2 updates from the same base.
        d1.deleteEntity('k0');
        d2.editScalar('k0', <String, int>{'a': 77});
        d1.push(server); // tombstone accepted first
        d2.push(server); // update loses to the tombstone, must be preserved

        _quiesce(server, <_Device>[d1, d2]);

        expect(server.entities['k0']!.tombstoned, isTrue);
        final List<ConflictArtifact> preserved = server.artifacts.values
            .where(
              (ConflictArtifact a) =>
                  a.policy == ConflictPolicyKind.tombstoneUpdatePreserved,
            )
            .toList();
        expect(preserved, hasLength(1));
        expect(preserved.single.localSnapshot!['a'], 77);
        // Not visible anywhere, but recoverable everywhere.
        for (final _Device d in <_Device>[d1, d2]) {
          expect(d.isVisible('k0'), isFalse);
          expect(
            d.artifacts.containsKey(preserved.single.remoteArtifactId),
            isTrue,
          );
        }
        _expectConverged(server, <_Device>[d1, d2]);
      },
    );

    testWithEvidence(
      _evidence('STALE-EPOCH-NO-RESURRECTION'),
      'a device that edits offline while its entity is tombstoned and purged '
      'past retention is rebased on bootstrap and never resurrects it',
      () {
        final _Server server = _Server();
        final _Device online = _Device(1)..adopt(server);
        final _Device offline = _Device(2)..adopt(server);

        online.insertScalar('k0');
        _quiesce(server, <_Device>[online, offline]);

        // The offline device queues an edit but does NOT sync.
        offline.editScalar('k0', <String, int>{'a': 999});

        // Meanwhile the online device deletes it and the server compacts past
        // retention: the tombstone is purged and the epoch advances.
        online.deleteEntity('k0');
        online.push(server);
        online.pull(server);
        server.compactRetention(purgeAll: true);
        expect(server.purged.contains('k0'), isTrue);

        // The offline device pushes with a stale epoch: rejected before any
        // mutation, forcing a bootstrap that drops the resurrecting edit.
        final _PushOutcome outcome = offline.push(server);
        expect(outcome, _PushOutcome.staleEpoch);

        _quiesce(server, <_Device>[online, offline]);

        // The entity is dead everywhere; nothing resurrected it.
        expect(server.entities.containsKey('k0'), isFalse);
        for (final _Device d in <_Device>[online, offline]) {
          expect(d.isVisible('k0'), isFalse);
        }
        _expectConverged(server, <_Device>[online, offline]);
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Scenario runner + assertions
// ---------------------------------------------------------------------------

final class _RunStats {
  const _RunStats({
    required this.artifacts,
    required this.purged,
    required this.staleRejections,
  });

  final int artifacts;
  final int purged;
  final int staleRejections;
}

_RunStats _runScenario(int seed) {
  final Random rng = Random(seed);
  final _Server server = _Server();
  final int deviceCount = 2 + rng.nextInt(4); // 2..5
  final List<_Device> devices = <_Device>[
    for (int i = 0; i < deviceCount; i += 1) _Device(i)..adopt(server),
  ];

  // Seed a small shared world from device 0, then sync everyone.
  final int scalarCount = 2 + rng.nextInt(2);
  final int noteCount = 1 + rng.nextInt(2);
  for (int i = 0; i < scalarCount; i += 1) {
    devices.first.insertScalar('k$i');
  }
  for (int i = 0; i < noteCount; i += 1) {
    devices.first.insertNote('n$i');
  }
  _quiesce(server, devices);

  final List<String> scalarIds = <String>[
    for (int i = 0; i < scalarCount; i += 1) 'k$i',
  ];
  final List<String> noteIds = <String>[
    for (int i = 0; i < noteCount; i += 1) 'n$i',
  ];

  int staleRejections = 0;
  final int steps = 20 + rng.nextInt(40);
  for (int step = 0; step < steps; step += 1) {
    final _Device device = devices[rng.nextInt(devices.length)];
    final int action = rng.nextInt(100);
    if (action < 34) {
      // Local scalar edit: 1..2 fields to a fresh value.
      final String id = scalarIds[rng.nextInt(scalarIds.length)];
      if (device.isVisible(id)) {
        final int fieldCount = 1 + rng.nextInt(2);
        final Map<String, int> edits = <String, int>{};
        final List<String> pool = List<String>.of(_scalarFields)..shuffle(rng);
        for (int f = 0; f < fieldCount; f += 1) {
          edits[pool[f]] = 1 + rng.nextInt(1000);
        }
        device.editScalar(id, edits);
      }
    } else if (action < 50) {
      // Local note edit on a random line.
      final String id = noteIds[rng.nextInt(noteIds.length)];
      if (device.isVisible(id)) {
        final int line = rng.nextInt(3);
        device.editNoteLine(id, line, 'd${device.id}-s$step');
      }
    } else if (action < 58) {
      // Local delete.
      final String id = scalarIds[rng.nextInt(scalarIds.length)];
      if (device.isVisible(id)) {
        device.deleteEntity(id);
      }
    } else if (action < 82) {
      // Push (may hit a stale epoch and bootstrap).
      final _PushOutcome outcome = device.push(server);
      if (outcome == _PushOutcome.staleEpoch) {
        staleRejections += 1;
      }
    } else if (action < 96) {
      // Pull to head.
      device.pull(server);
    } else {
      // Server retention compaction: advance the epoch and purge some
      // tombstones, making lagging devices stale.
      server.compactRetention(purgeAll: rng.nextBool());
    }
  }

  _quiesce(server, devices);
  _expectConverged(server, devices);

  return _RunStats(
    artifacts: server.artifacts.length,
    purged: server.purged.length,
    staleRejections: staleRejections,
  );
}

/// Drives the system to quiescence: repeatedly push every device's pending
/// intents (bootstrapping on stale epoch) and pull everyone to head until a
/// fixpoint. A bounded iteration guard fails loudly rather than masking a
/// non-terminating (non-converging) model.
void _quiesce(_Server server, List<_Device> devices) {
  final int maxRounds = 4 * devices.length + 8;
  for (int round = 0; round <= maxRounds; round += 1) {
    for (final _Device device in devices) {
      device.pushUntilAccepted(server);
    }
    for (final _Device device in devices) {
      device.pull(server);
    }
    final bool settled = devices.every(
      (_Device d) =>
          d.pending.isEmpty &&
          d.cursor == server.head &&
          d.epoch == server.epoch,
    );
    if (settled) {
      return;
    }
    if (round == maxRounds) {
      fail(
        'system failed to quiesce within $maxRounds rounds (non-convergence)',
      );
    }
  }
}

/// Asserts every device converged to the identical server-accepted visible
/// state, that no purged entity is visible anywhere, and that every durable
/// losing value the server recorded is present and intact on every device.
void _expectConverged(_Server server, List<_Device> devices) {
  final Map<String, Map<String, Object?>> serverVisible = server.visibleState();
  for (final _Device device in devices) {
    expect(
      device.visibleState(),
      serverVisible,
      reason: 'device ${device.id} did not converge to server-accepted state',
    );
    // No purged/tombstoned entity is visible.
    for (final String purged in server.purged) {
      expect(
        device.isVisible(purged),
        isFalse,
        reason: 'device ${device.id} resurrected purged entity $purged',
      );
    }
    // Every losing value is recoverable: same artifact id + intact snapshot.
    for (final ConflictArtifact artifact in server.artifacts.values) {
      final ConflictArtifact? held =
          device.artifacts[artifact.remoteArtifactId];
      expect(
        held,
        isNotNull,
        reason:
            'device ${device.id} is missing artifact '
            '${artifact.remoteArtifactId} (losing value not recoverable)',
      );
      expect(
        held!.localSnapshot,
        artifact.localSnapshot,
        reason:
            'device ${device.id} lost the preserved losing value for '
            '${artifact.remoteArtifactId}',
      );
      expect(held.policy, artifact.policy);
    }
  }
}

// ---------------------------------------------------------------------------
// Model: a durable row, the authority server, and a device.
// ---------------------------------------------------------------------------

/// A stored entity row (server-side or a device's local projection).
final class _Row {
  _Row({
    required this.values,
    required this.fieldVersions,
    required this.rowVersion,
    required this.tombstoned,
  });

  factory _Row.scalarInitial() => _Row(
    values: <String, Object?>{for (final String f in _scalarFields) f: 0},
    fieldVersions: <String, int>{for (final String f in _scalarFields) f: 1},
    rowVersion: 1,
    tombstoned: false,
  );

  factory _Row.noteInitial() => _Row(
    values: <String, Object?>{'body': _initialBody},
    fieldVersions: <String, int>{'body': 1},
    rowVersion: 1,
    tombstoned: false,
  );

  Map<String, Object?> values;
  Map<String, int> fieldVersions;
  int rowVersion;
  bool tombstoned;

  _Row clone() => _Row(
    values: Map<String, Object?>.of(values),
    fieldVersions: Map<String, int>.of(fieldVersions),
    rowVersion: rowVersion,
    tombstoned: tombstoned,
  );
}

bool _isNote(String entityId) => entityId.startsWith('n');
String _entityType(String entityId) => _isNote(entityId) ? 'note' : 'scalar';

/// The kind of a queued local intent.
enum _OpKind { update, delete }

/// One coalesced pending local intent for an entity. It captures the exact
/// base it was authored against (values + field versions) so the server can
/// evaluate contention faithfully; the intended new values are snapshotted so a
/// later pull cannot mutate them.
final class _PushOp {
  _PushOp({
    required this.entityId,
    required this.kind,
    required this.baseValues,
    required this.baseFieldVersions,
    required this.changedFields,
    required this.values,
  });

  final String entityId;
  _OpKind kind;
  Map<String, Object?> baseValues;
  Map<String, int> baseFieldVersions;
  Set<String> changedFields;
  Map<String, Object?> values;

  String get entityType => _entityType(entityId);
}

enum _PushOutcome { accepted, staleEpoch, nothingToPush }

/// The authority. It sequences accepted changes, maintains per-field versions,
/// epochs, durable conflict artifacts, and a feed devices pull in order. Every
/// conflict *decision* is delegated to the real domain policies.
final class _Server {
  final Map<String, _Row> entities = <String, _Row>{};
  final Set<String> purged = <String>{};
  final Map<String, ConflictArtifact> artifacts = <String, ConflictArtifact>{};
  final List<_FeedEntry> feed = <_FeedEntry>[];

  final EntityConflictPolicy _policy = const EntityConflictPolicy();

  int _seq = 0;
  int epoch = 0;
  int _artifactCounter = 0;
  int _clock = 0;

  int get head => _seq;

  int _nextClock() => ++_clock;

  String _newArtifactId() => 'art-e$epoch-${_artifactCounter++}';

  void _appendEntity(String entityId) {
    _seq += 1;
    feed.add(_FeedEntry(seq: _seq, epoch: epoch, entityId: entityId));
  }

  void _appendArtifact(ConflictArtifact artifact) {
    artifacts[artifact.remoteArtifactId] = artifact;
    _seq += 1;
    feed.add(
      _FeedEntry(
        seq: _seq,
        epoch: epoch,
        artifactId: artifact.remoteArtifactId,
      ),
    );
  }

  /// Advances the epoch and purges retained tombstones, modelling retention
  /// compaction. A device that has not caught up becomes stale and must
  /// bootstrap before it may push again.
  void compactRetention({required bool purgeAll}) {
    epoch += 1;
    final List<String> tombstoned = <String>[
      for (final MapEntry<String, _Row> e in entities.entries)
        if (e.value.tombstoned) e.key,
    ];
    for (int i = 0; i < tombstoned.length; i += 1) {
      if (purgeAll || i.isEven) {
        entities.remove(tombstoned[i]);
        purged.add(tombstoned[i]);
      }
    }
    // Record the epoch bump on the feed so pulling devices adopt the new epoch.
    _seq += 1;
    feed.add(_FeedEntry(seq: _seq, epoch: epoch));
  }

  /// Pushes a whole semantic group. A stale epoch is rejected before any
  /// mutation (R-SYNC-003); otherwise every operation is applied in order and
  /// each losing value is preserved in a durable artifact.
  _PushOutcome pushGroup(int deviceEpoch, List<_PushOp> ops) {
    if (deviceEpoch < epoch) {
      return _PushOutcome.staleEpoch;
    }
    for (final _PushOp op in ops) {
      if (op.kind == _OpKind.delete) {
        _applyDelete(op);
      } else if (op.entityType == 'note') {
        _applyNote(op);
      } else {
        _applyScalar(op);
      }
    }
    return _PushOutcome.accepted;
  }

  void _applyScalar(_PushOp op) {
    final _Row? existing = entities[op.entityId];
    if (existing == null) {
      if (purged.contains(op.entityId)) {
        return; // never resurrect a purged entity
      }
      entities[op.entityId] = _Row(
        values: <String, Object?>{
          for (final String f in op.changedFields) f: op.values[f],
        },
        fieldVersions: <String, int>{
          for (final String f in op.changedFields) f: 1,
        },
        rowVersion: 1,
        tombstoned: false,
      );
      _appendEntity(op.entityId);
      return;
    }
    if (existing.tombstoned) {
      _preserveUpdateAgainstTombstone(op);
      return;
    }

    final EntityEdit localEdit = EntityEdit(
      changedFields: op.changedFields,
      values: <String, Object?>{
        for (final String f in op.changedFields) f: op.values[f],
      },
    );
    final Set<String> remoteChanged = <String>{
      for (final MapEntry<String, int> e in existing.fieldVersions.entries)
        if (e.value > (op.baseFieldVersions[e.key] ?? 0)) e.key,
    };
    final EntityEdit remoteEdit = EntityEdit(
      changedFields: remoteChanged,
      values: <String, Object?>{
        for (final String f in remoteChanged) f: existing.values[f],
      },
    );

    final FieldMergeResult result = _policy.resolveFields(
      entityType: op.entityType,
      entityId: op.entityId,
      local: localEdit,
      remote: remoteEdit,
      baseValues: op.baseValues,
      createdAtUtc: _nextClock(),
      artifactId: _newArtifactId(),
    );

    for (final String field in result.mergedFromLocal) {
      existing.values[field] = result.mergedValues[field];
      existing.fieldVersions[field] = (existing.fieldVersions[field] ?? 0) + 1;
    }
    existing.rowVersion += 1;
    if (result.artifact != null) {
      _appendArtifact(result.artifact!);
    }
    _appendEntity(op.entityId);
  }

  void _applyNote(_PushOp op) {
    final _Row? existing = entities[op.entityId];
    final String newBody = op.values['body']! as String;
    final String baseBody = op.baseValues['body']! as String;
    if (existing == null) {
      if (purged.contains(op.entityId)) {
        return;
      }
      entities[op.entityId] = _Row(
        values: <String, Object?>{'body': newBody},
        fieldVersions: <String, int>{'body': 1},
        rowVersion: 1,
        tombstoned: false,
      );
      _appendEntity(op.entityId);
      return;
    }
    if (existing.tombstoned) {
      _preserveUpdateAgainstTombstone(op);
      return;
    }

    final String serverBody = existing.values['body']! as String;
    final NoteMergeResult merge = mergeNoteBody(
      base: baseBody,
      local: newBody,
      remote: serverBody,
    );
    if (merge.isMerged) {
      existing.values['body'] = merge.mergedBody;
      existing.fieldVersions['body'] =
          (existing.fieldVersions['body'] ?? 0) + 1;
      existing.rowVersion += 1;
      _appendEntity(op.entityId);
      return;
    }
    // Conflict copy: the server-accepted body stays visible and the pushing
    // device's body is preserved as the losing value in a durable artifact.
    _appendArtifact(
      ConflictArtifact(
        remoteArtifactId: _newArtifactId(),
        entityType: 'note',
        entityId: op.entityId,
        policy: ConflictPolicyKind.noteConflictCopy,
        fields: const <String>['body'],
        createdAtUtc: _nextClock(),
        baseSnapshot: <String, Object?>{'body': baseBody},
        localSnapshot: <String, Object?>{'body': newBody},
        remoteSnapshot: <String, Object?>{'body': serverBody},
      ),
    );
    // Visible body unchanged; still stamp the row so devices re-sync it.
    _appendEntity(op.entityId);
  }

  void _applyDelete(_PushOp op) {
    final _Row? existing = entities[op.entityId];
    if (existing == null) {
      if (purged.contains(op.entityId)) {
        return;
      }
      entities[op.entityId] = _Row(
        values: <String, Object?>{},
        fieldVersions: <String, int>{},
        rowVersion: 1,
        tombstoned: true,
      );
      _appendEntity(op.entityId);
      return;
    }
    if (existing.tombstoned) {
      return; // idempotent
    }
    // A concurrent server update since the delete's base is the losing value.
    final Set<String> remoteChanged = <String>{
      for (final MapEntry<String, int> e in existing.fieldVersions.entries)
        if (e.value > (op.baseFieldVersions[e.key] ?? 0)) e.key,
    };
    if (remoteChanged.isNotEmpty) {
      final TombstoneMergeResult result = _policy.resolveDeleteVersusUpdate(
        entityType: op.entityType,
        entityId: op.entityId,
        survivingUpdate: EntityEdit(
          changedFields: remoteChanged,
          values: <String, Object?>{
            for (final String f in remoteChanged) f: existing.values[f],
          },
        ),
        baseValues: op.baseValues,
        createdAtUtc: _nextClock(),
        artifactId: _newArtifactId(),
      );
      if (result.artifact != null) {
        _appendArtifact(result.artifact!);
      }
    }
    existing.tombstoned = true;
    existing.rowVersion += 1;
    _appendEntity(op.entityId);
  }

  void _preserveUpdateAgainstTombstone(_PushOp op) {
    // Rule 8: the tombstone wins the visible state; the incoming update is the
    // losing value and is preserved so it is never silently lost.
    final Set<String> updated = op.entityType == 'note'
        ? <String>{'body'}
        : op.changedFields;
    final TombstoneMergeResult result = _policy.resolveDeleteVersusUpdate(
      entityType: op.entityType,
      entityId: op.entityId,
      survivingUpdate: EntityEdit(
        changedFields: updated,
        values: <String, Object?>{
          for (final String f in updated) f: op.values[f],
        },
      ),
      baseValues: op.baseValues,
      createdAtUtc: _nextClock(),
      artifactId: _newArtifactId(),
    );
    if (result.artifact != null) {
      _appendArtifact(result.artifact!);
    }
    // Visible state stays the tombstone; no resurrection.
  }

  /// The server-accepted visible state: live (non-tombstoned) rows only.
  Map<String, Map<String, Object?>> visibleState() =>
      <String, Map<String, Object?>>{
        for (final MapEntry<String, _Row> e in entities.entries)
          if (!e.value.tombstoned)
            e.key: Map<String, Object?>.of(e.value.values),
      };
}

/// The feed record a device pulls: either an entity change, a durable artifact,
/// or an epoch-advance marker.
final class _FeedEntry {
  _FeedEntry({
    required this.seq,
    required this.epoch,
    this.entityId,
    this.artifactId,
  });

  final int seq;
  final int epoch;
  final String? entityId;
  final String? artifactId;
}

/// A device: its local projection (including un-pushed pending intents),
/// coalesced pending intents, cursor, and epoch.
final class _Device {
  _Device(this.id);

  final int id;
  final Map<String, _Row> local = <String, _Row>{};
  final Map<String, ConflictArtifact> artifacts = <String, ConflictArtifact>{};
  final Map<String, _PushOp> pending = <String, _PushOp>{};

  int cursor = 0;
  int epoch = 0;

  bool isVisible(String entityId) {
    final _Row? row = local[entityId];
    return row != null && !row.tombstoned;
  }

  /// Snapshots the server's current state (used for the initial join and for a
  /// bootstrap after a stale-epoch rejection).
  void adopt(_Server server) {
    local
      ..clear()
      ..addAll(<String, _Row>{
        for (final MapEntry<String, _Row> e in server.entities.entries)
          e.key: e.value.clone(),
      });
    for (final String purged in server.purged) {
      local[purged] = _Row(
        values: <String, Object?>{},
        fieldVersions: <String, int>{},
        rowVersion: 1,
        tombstoned: true,
      );
    }
    artifacts
      ..clear()
      ..addAll(server.artifacts);
    cursor = server.head;
    epoch = server.epoch;
  }

  // --- local intents -------------------------------------------------------

  void insertScalar(String id) {
    local[id] = _Row.scalarInitial();
    pending[id] = _PushOp(
      entityId: id,
      kind: _OpKind.update,
      baseValues: <String, Object?>{for (final String f in _scalarFields) f: 0},
      baseFieldVersions: <String, int>{
        for (final String f in _scalarFields) f: 0,
      },
      changedFields: Set<String>.of(_scalarFields),
      values: <String, Object?>{for (final String f in _scalarFields) f: 0},
    );
  }

  void insertNote(String id) {
    local[id] = _Row.noteInitial();
    pending[id] = _PushOp(
      entityId: id,
      kind: _OpKind.update,
      baseValues: <String, Object?>{'body': _initialBody},
      baseFieldVersions: <String, int>{'body': 0},
      changedFields: <String>{'body'},
      values: <String, Object?>{'body': _initialBody},
    );
  }

  void editScalar(String id, Map<String, int> edits) {
    final _Row row = local[id]!;
    final _PushOp op = _ensureUpdateOp(id);
    for (final MapEntry<String, int> e in edits.entries) {
      row.values[e.key] = e.value; // local projection reflects the edit
      op.changedFields.add(e.key);
      op.values[e.key] = e.value;
    }
  }

  void editNoteLine(String id, int line, String text) {
    final _Row row = local[id]!;
    // Capture the base BEFORE mutating the local projection so the op records
    // the body the edit was authored against (not the post-edit body).
    final _PushOp op = _ensureUpdateOp(id);
    final List<String> lines = _splitBody(row.values['body']! as String);
    while (lines.length <= line) {
      lines.add('');
    }
    lines[line] = text;
    final String body = '${lines.join('\n')}\n';
    row.values['body'] = body;
    op.changedFields.add('body');
    op.values['body'] = body;
  }

  void deleteEntity(String id) {
    final _Row row = local[id]!;
    final _PushOp op = _ensureUpdateOp(id);
    op.kind = _OpKind.delete;
    row.tombstoned = true; // local projection reflects the delete
  }

  /// Gets or creates the coalesced pending op for [id], capturing the base
  /// (values + field versions) at first authoring since the last sync.
  _PushOp _ensureUpdateOp(String id) {
    final _PushOp? existing = pending[id];
    if (existing != null) {
      return existing;
    }
    final _Row row = local[id]!;
    final _PushOp op = _PushOp(
      entityId: id,
      kind: _OpKind.update,
      baseValues: Map<String, Object?>.of(row.values),
      baseFieldVersions: Map<String, int>.of(row.fieldVersions),
      changedFields: <String>{},
      values: <String, Object?>{},
    );
    pending[id] = op;
    return op;
  }

  // --- exchange ------------------------------------------------------------

  /// Pushes all pending intents once. On a stale epoch it bootstraps (which
  /// rebases pending intents and drops any that would resurrect a purged
  /// entity) and returns [_PushOutcome.staleEpoch] without retrying.
  _PushOutcome push(_Server server) {
    if (pending.isEmpty) {
      return _PushOutcome.nothingToPush;
    }
    final List<_PushOp> ops = pending.values.toList(growable: false);
    final _PushOutcome outcome = server.pushGroup(epoch, ops);
    if (outcome == _PushOutcome.staleEpoch) {
      _bootstrap(server);
      return _PushOutcome.staleEpoch;
    }
    pending.clear();
    epoch = server.epoch;
    return outcome;
  }

  /// Pushes repeatedly until nothing is pending: a stale epoch triggers a
  /// bootstrap and the rebased intents are pushed under the fresh epoch.
  void pushUntilAccepted(_Server server) {
    int guard = 0;
    while (pending.isNotEmpty) {
      final _PushOutcome outcome = push(server);
      if (outcome == _PushOutcome.accepted ||
          outcome == _PushOutcome.nothingToPush) {
        return;
      }
      guard += 1;
      if (guard > 4) {
        fail('device $id could not push after repeated bootstraps');
      }
    }
  }

  /// Applies every feed entry after the cursor, converging the local projection
  /// on the server-accepted state and advancing the cursor and epoch to head.
  void pull(_Server server) {
    for (final _FeedEntry entry in server.feed) {
      if (entry.seq <= cursor) {
        continue;
      }
      if (entry.artifactId != null) {
        artifacts[entry.artifactId!] = server.artifacts[entry.artifactId!]!;
      } else if (entry.entityId != null) {
        final String eid = entry.entityId!;
        final _Row? row = server.entities[eid];
        if (row != null) {
          local[eid] = row.clone();
        } else if (server.purged.contains(eid)) {
          local[eid] = _Row(
            values: <String, Object?>{},
            fieldVersions: <String, int>{},
            rowVersion: 1,
            tombstoned: true,
          );
        }
      }
    }
    cursor = server.head;
    epoch = server.epoch;
  }

  /// Bootstrap after a stale-epoch rejection: adopt the server's current state
  /// and rebase pending intents onto it. Intents targeting a purged entity are
  /// dropped so they can never resurrect it; surviving intents are rebased onto
  /// the freshly adopted base.
  void _bootstrap(_Server server) {
    final Map<String, _PushOp> carried = Map<String, _PushOp>.of(pending);
    adopt(server);
    pending.clear();
    for (final MapEntry<String, _PushOp> e in carried.entries) {
      final String id = e.key;
      final _PushOp op = e.value;
      if (server.purged.contains(id)) {
        continue; // resurrection prevented: the entity is retired past retention
      }
      final _Row? row = local[id];
      // Rebase the intent's base onto the adopted server state.
      op.baseValues = row == null
          ? <String, Object?>{}
          : Map<String, Object?>.of(row.values);
      op.baseFieldVersions = row == null
          ? <String, int>{}
          : Map<String, int>.of(row.fieldVersions);
      // Re-apply the intent to the local projection so it stays visible.
      if (op.kind == _OpKind.delete) {
        if (row != null) {
          row.tombstoned = true;
        }
      } else {
        final _Row target = local[id] ??= _isNote(id)
            ? _Row.noteInitial()
            : _Row.scalarInitial();
        for (final String f in op.changedFields) {
          target.values[f] = op.values[f];
        }
      }
      pending[id] = op;
    }
  }

  Map<String, Map<String, Object?>> visibleState() =>
      <String, Map<String, Object?>>{
        for (final MapEntry<String, _Row> e in local.entries)
          if (!e.value.tombstoned)
            e.key: Map<String, Object?>.of(e.value.values),
      };
}

List<String> _splitBody(String body) {
  final String trimmed = body.endsWith('\n')
      ? body.substring(0, body.length - 1)
      : body;
  return trimmed.split('\n');
}
