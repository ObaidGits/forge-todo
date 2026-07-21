import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/features/areas/application/life_area_commands.dart';

/// The durable Life Area command surface (R-GEN-002, R-GEN-005).
///
/// Every method commits one atomic transaction through the command bus and
/// returns the stable committed result. [commandId] makes each call idempotent:
/// replaying the same id with the same request returns the stored result; a
/// different request under the same id is rejected as a conflict.
abstract interface class LifeAreaCommandService {
  /// Creates a Life Area (R-GEN-002). The result payload carries the generated
  /// area id. A duplicate name for the profile is rejected.
  Future<Result<CommittedCommandResult>> create({
    required CommandId commandId,
    required ProfileId profileId,
    required CreateLifeAreaInput input,
  });

  /// Renames a Life Area (R-GEN-002). A name that collides with another area is
  /// rejected.
  Future<Result<CommittedCommandResult>> rename({
    required CommandId commandId,
    required ProfileId profileId,
    required LifeAreaId areaId,
    required RenameLifeAreaInput input,
  });

  /// Reorders a Life Area between two neighbours (R-GEN-002). Never rewrites the
  /// neighbouring ranks.
  Future<Result<CommittedCommandResult>> reorder({
    required CommandId commandId,
    required ProfileId profileId,
    required LifeAreaId areaId,
    required ReorderLifeAreaInput input,
  });

  /// Archives a Life Area (R-GEN-002). The area remains queryable and keeps its
  /// records; the profile's default area cannot be archived.
  Future<Result<CommittedCommandResult>> archive({
    required CommandId commandId,
    required ProfileId profileId,
    required LifeAreaId areaId,
  });

  /// Restores an archived Life Area (R-GEN-002).
  Future<Result<CommittedCommandResult>> restore({
    required CommandId commandId,
    required ProfileId profileId,
    required LifeAreaId areaId,
  });

  /// Makes [areaId] the profile's single default area (R-GEN-002). The previous
  /// default is cleared in the same transaction so at most one default exists.
  /// An archived area cannot become the default.
  Future<Result<CommittedCommandResult>> makeDefault({
    required CommandId commandId,
    required ProfileId profileId,
    required LifeAreaId areaId,
  });
}
