/// Bootstrap local inventory value semantics (R-SYNC-006).
///
/// The inventory preserves everything and cleanly separates a pending command's
/// receipt (imported only after its intent rebases) from a settled receipt
/// (copied normally), and orders pending commands by commit sequence — the
/// exact order rebase must replay them in.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/sync/domain/bootstrap/local_inventory.dart';

import '../../helpers/evidence.dart';

EvidenceMetadata _evidence(String suffix) => EvidenceMetadata(
  evidenceId: EvidenceId('TEST-SYNC-BOOTSTRAP-INVENTORY-$suffix'),
  releaseTag: ReleaseTag.v1,
  taskId: SpecTaskId('9.5'),
  requirements: <RequirementId>[RequirementId('R-SYNC-006')],
);

ReceiptRecord _receipt(String commandId, {int commitSeq = 1}) => ReceiptRecord(
  commandId: commandId,
  requestHash: 'hash-$commandId',
  resultCode: 'ok',
  payloadVersion: 1,
  commitSeq: commitSeq,
);

PendingCommandRecord _pending(String commandId, int commitSeq) =>
    PendingCommandRecord(
      commandId: commandId,
      commitSeq: commitSeq,
      commandType: 'task.create',
      entityType: 'task',
      entityId: 'entity-$commandId',
      canonicalPayload: '{"title":"$commandId"}',
      originalResultCode: 'ok',
      originalPayloadVersion: 1,
    );

void main() {
  group('LocalInventory', () {
    testWithEvidence(
      _evidence('ORDERS-PENDING-BY-COMMIT-SEQ'),
      'pending commands are exposed in ascending commit order',
      () {
        final LocalInventory inventory = LocalInventory(
          commitSeq: 10,
          pendingCommands: <PendingCommandRecord>[
            _pending('c3', 7),
            _pending('c1', 3),
            _pending('c2', 5),
          ],
        );
        expect(
          inventory.pendingCommands
              .map((PendingCommandRecord c) => c.commandId)
              .toList(),
          <String>['c1', 'c2', 'c3'],
        );
      },
    );

    testWithEvidence(
      _evidence('SPLITS-PENDING-VS-SETTLED-RECEIPTS'),
      'a pending command receipt is separated from settled receipts',
      () {
        final LocalInventory inventory = LocalInventory(
          commitSeq: 10,
          receipts: <ReceiptRecord>[
            _receipt('c1'),
            _receipt('c2'),
            _receipt('settled-1'),
          ],
          pendingCommands: <PendingCommandRecord>[
            _pending('c1', 3),
            _pending('c2', 5),
          ],
        );
        expect(
          inventory.pendingCommandReceipts
              .map((ReceiptRecord r) => r.commandId)
              .toSet(),
          <String>{'c1', 'c2'},
        );
        expect(
          inventory.settledReceipts
              .map((ReceiptRecord r) => r.commandId)
              .toList(),
          <String>['settled-1'],
        );
        // No receipt is lost across the split.
        expect(
          inventory.pendingCommandReceipts.length +
              inventory.settledReceipts.length,
          inventory.receipts.length,
        );
      },
    );

    testWithEvidence(
      _evidence('REJECTS-NEGATIVE-COMMIT-SEQ'),
      'a negative commit sequence is rejected',
      () {
        expect(
          () => LocalInventory(commitSeq: -1),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    testWithEvidence(
      _evidence('LOCAL-ONLY-ITEM-REQUIRES-HASH'),
      'a local-only item requires a non-empty content hash',
      () {
        expect(
          () => LocalOnlyItem(
            kind: LocalOnlyKind.draft,
            id: 'draft-1',
            contentHash: '',
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );
  });
}
