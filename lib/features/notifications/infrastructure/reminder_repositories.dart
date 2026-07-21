import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/transaction_scope.dart';
import 'package:forge/features/notifications/application/reminder_service.dart';
import 'package:forge/features/notifications/domain/reminder.dart';
import 'package:forge/features/notifications/domain/reminder_diagnostics.dart';
import 'package:forge/features/notifications/domain/reminder_repository.dart';
import 'package:forge/features/notifications/infrastructure/reminder_mapper.dart';

/// Non-transactional read access to the `reminders` table plus the local-only
/// reconciliation projection writer (R-NOTIFY-003/004).
///
/// Reads run outside a command transaction. The projection writer applies the
/// local-only cached fields (next-fire, delivery status, last diagnostic) in a
/// single Drift transaction; these fields are never replicated, so this is not
/// a durable domain command.
final class ReminderReadRepositoryDrift
    implements ReminderReadRepository, ReminderProjectionWriter {
  ReminderReadRepositoryDrift(this.db);

  final ForgeSchemaDatabase db;

  @override
  Future<List<Reminder>> enabledReminders(String profileId) async {
    final List<ReminderRow> rows =
        await (db.select(db.reminders)
              ..where(
                (Reminders t) =>
                    t.profileId.equals(profileId) &
                    t.enabled.equals(true) &
                    t.deletedAtUtc.isNull(),
              )
              ..orderBy(<OrderingTerm Function(Reminders)>[
                (Reminders t) => OrderingTerm(expression: t.id),
              ]))
            .get();
    return rows.map(ReminderMapper.fromRow).toList(growable: false);
  }

  @override
  Future<Reminder?> find(String profileId, String reminderId) async {
    final ReminderRow? row =
        await (db.select(db.reminders)..where(
              (Reminders t) =>
                  t.profileId.equals(profileId) & t.id.equals(reminderId),
            ))
            .getSingleOrNull();
    return row == null ? null : ReminderMapper.fromRow(row);
  }

  @override
  Future<List<Reminder>> forOwner(
    String profileId, {
    required String ownerType,
    required String ownerId,
  }) async {
    final List<ReminderRow> rows =
        await (db.select(db.reminders)
              ..where(
                (Reminders t) =>
                    t.profileId.equals(profileId) &
                    t.ownerType.equals(ownerType) &
                    t.ownerId.equals(ownerId) &
                    t.deletedAtUtc.isNull(),
              )
              ..orderBy(<OrderingTerm Function(Reminders)>[
                (Reminders t) => OrderingTerm(expression: t.id),
              ]))
            .get();
    return rows.map(ReminderMapper.fromRow).toList(growable: false);
  }

  @override
  Future<void> record({
    required String profileId,
    required List<Reminder> reminders,
    required Map<String, int> placed,
    required List<ReminderDiagnostic> diagnostics,
    required int nowUtc,
  }) async {
    // Index scheduler-wide diagnostics and per-reminder diagnostics so each
    // reminder row can render an honest last-diagnostic (R-NOTIFY-003).
    final List<ReminderDiagnostic> wide = diagnostics
        .where((ReminderDiagnostic d) => d.reminderId == null)
        .toList(growable: false);
    final Map<String, ReminderDiagnostic> byReminder =
        <String, ReminderDiagnostic>{
          for (final ReminderDiagnostic d in diagnostics)
            if (d.reminderId != null) d.reminderId!: d,
        };
    final ReminderDiagnosticCode? wideCode = wide.isEmpty
        ? null
        : wide.first.code;

    await db.transaction(() async {
      for (final Reminder reminder in reminders) {
        final int? fireAt = placed[reminder.id.value];
        final ReminderDiagnostic? own = byReminder[reminder.id.value];
        final ReminderDiagnosticCode? code = own?.code ?? wideCode;
        final ReminderDeliveryStatus status = fireAt != null
            ? ReminderDeliveryStatus.scheduled
            : (code == ReminderDiagnosticCode.schedulerFailure
                  ? ReminderDeliveryStatus.failed
                  : (code == null
                        ? ReminderDeliveryStatus.pending
                        : ReminderDeliveryStatus.skipped));
        await (db.update(db.reminders)..where(
              (Reminders t) =>
                  t.profileId.equals(profileId) &
                  t.id.equals(reminder.id.value),
            ))
            .write(
              RemindersCompanion(
                nextFireAtUtc: Value<int?>(fireAt),
                deliveryStatus: Value<String>(status.wire),
                lastDiagnosticCode: Value<String?>(code?.wire),
                updatedAtUtc: Value<int>(nowUtc),
              ),
            );
      }
    });
  }
}

/// Transaction-scoped write access to the `reminders` table, resolved from the
/// session repository set inside a command body (design §5).
final class ReminderWriteRepository {
  ReminderWriteRepository(this.db, this.scope);

  final ForgeSchemaDatabase db;
  final TransactionScope scope;

  Future<Reminder?> find(String profileId, String reminderId) async {
    scope.ensureActive();
    final ReminderRow? row =
        await (db.select(db.reminders)..where(
              (Reminders t) =>
                  t.profileId.equals(profileId) & t.id.equals(reminderId),
            ))
            .getSingleOrNull();
    return row == null ? null : ReminderMapper.fromRow(row);
  }

  Future<void> insert(Reminder reminder) async {
    scope.ensureActive();
    await db.into(db.reminders).insert(ReminderMapper.toInsert(reminder));
  }

  Future<void> update(Reminder reminder) async {
    scope.ensureActive();
    await (db.update(db.reminders)..where(
          (Reminders t) =>
              t.profileId.equals(reminder.profileId.value) &
              t.id.equals(reminder.id.value),
        ))
        .write(ReminderMapper.toUpdate(reminder));
  }

  /// The current epoch stamped on outbox operations. Falls back to `0` before a
  /// sync profile link exists (mirrors the tasks repository).
  Future<int> currentEpoch(String profileId) async {
    scope.ensureActive();
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT COALESCE(MAX(epoch), 0) AS e FROM sync_cursors '
          'WHERE profile_id = ?',
          variables: <Variable<Object>>[Variable<String>(profileId)],
        )
        .get();
    return rows.single.data['e'] as int;
  }
}
