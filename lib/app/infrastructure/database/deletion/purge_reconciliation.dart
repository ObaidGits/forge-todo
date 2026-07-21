import 'package:forge/app/infrastructure/database/deletion/deletion_repositories.dart';
import 'package:forge/app/infrastructure/database/deletion/purge_preview.dart';
import 'package:forge/app/infrastructure/database/deletion/trashable_entity.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';

/// The purge-eligibility report produced by automatic reconciliation.
///
/// Reporting is non-destructive: it names the soft-deleted rows whose trash
/// retention has elapsed so the UI can surface them, but it never purges. Hard
/// purge remains a separate previewed, confirmed, block-checked command
/// (R-GEN-003).
final class PurgeEligibilityReport {
  const PurgeEligibilityReport({
    required this.eligible,
    required this.generatedAtUtc,
    required this.retentionCutoffUtc,
  });

  /// Rows whose trash retention elapsed at or before [retentionCutoffUtc].
  final List<EntityRef> eligible;

  /// When the report was produced.
  final int generatedAtUtc;

  /// The instant at/before which a soft-deletion becomes purge-eligible.
  final int retentionCutoffUtc;

  int get eligibleCount => eligible.length;
}

/// Automatic trash reconciliation that only marks/reports purge eligibility
/// (R-GEN-003). Runs on startup/resume; performs no destructive work.
final class PurgeReconciliationService {
  PurgeReconciliationService({
    required this.unitOfWork,
    required this.clock,
    required this.registry,
    this.trashRetention = const Duration(days: 30),
  });

  final UnitOfWork unitOfWork;
  final Clock clock;
  final TrashRegistry registry;

  /// Default trash window before a soft-deletion becomes purge-eligible.
  final Duration trashRetention;

  /// Reports every purge-eligible row across all registered trashable entities.
  Future<PurgeEligibilityReport> report(ProfileId profile) {
    final int now = clock.utcNow().microsecondsSinceEpoch;
    final int cutoff = now - trashRetention.inMicroseconds;
    return unitOfWork.transaction<PurgeEligibilityReport>((
      TransactionSession session,
    ) async {
      final TrashRepository trash = session.repositories
          .resolve<TrashRepository>();
      final List<EntityRef> eligible = <EntityRef>[];
      for (final TrashableEntity descriptor in registry.all) {
        final List<String> ids = await trash.eligibleForPurge(
          descriptor,
          profile.value,
          cutoff,
        );
        for (final String id in ids) {
          eligible.add(
            EntityRef(entityType: descriptor.entityType, entityId: id),
          );
        }
      }
      eligible.sort();
      return PurgeEligibilityReport(
        eligible: eligible,
        generatedAtUtc: now,
        retentionCutoffUtc: cutoff,
      );
    });
  }
}
