import 'package:forge/core/domain/id.dart';
import 'package:forge/features/focus/domain/focus_event.dart';
import 'package:forge/features/focus/domain/focus_interval.dart';
import 'package:forge/features/focus/domain/focus_session.dart';

/// Read access to focus aggregates. Query methods run outside a write
/// transaction and return immutable domain aggregates (design.md §5 "Queries").
abstract interface class FocusRepository {
  /// The session with [sessionId], or null when absent for [profileId].
  Future<FocusSession?> findSession(
    ProfileId profileId,
    FocusSessionId sessionId,
  );

  /// The single open (running or paused) session for [profileId], or null when
  /// none is open (R-FOCUS-003 one-open constraint).
  Future<FocusSession?> openSession(ProfileId profileId);

  /// The append-only lifecycle events of a session, oldest first (R-FOCUS-003).
  Future<List<FocusEvent>> events(
    ProfileId profileId,
    FocusSessionId sessionId,
  );

  /// The projected intervals of a session, ordered by start (R-FOCUS-003).
  Future<List<FocusInterval>> intervals(
    ProfileId profileId,
    FocusSessionId sessionId,
  );

  /// The unioned focus work seconds over a transparent range, optionally scoped
  /// to a life area. Overlapping work intervals are counted once (R-FOCUS-005).
  Future<int> focusDurationSec(
    ProfileId profileId, {
    required int rangeStartUtc,
    required int rangeEndUtc,
    LifeAreaId? lifeAreaId,
  });
}
