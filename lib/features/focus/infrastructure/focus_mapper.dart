import 'package:drift/drift.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/focus/domain/focus_event.dart';
import 'package:forge/features/focus/domain/focus_event_kind.dart';
import 'package:forge/features/focus/domain/focus_interval.dart';
import 'package:forge/features/focus/domain/focus_interval_kind.dart';
import 'package:forge/features/focus/domain/focus_link.dart';
import 'package:forge/features/focus/domain/focus_mode.dart';
import 'package:forge/features/focus/domain/focus_session.dart';
import 'package:forge/features/focus/domain/focus_session_status.dart';

/// Explicit mapping between focus Drift rows and immutable domain aggregates.
abstract final class FocusMapper {
  // ---- focus_sessions -----------------------------------------------------

  static FocusSession sessionFromRow(FocusSessionRow row) {
    final FocusLink? link = row.linkTargetType == null
        ? null
        : FocusLink(
            type: FocusLinkType.fromWire(row.linkTargetType!),
            targetId: row.linkTargetId!,
          );
    return FocusSession(
      id: FocusSessionId(row.id),
      profileId: ProfileId(row.profileId),
      lifeAreaId: LifeAreaId(row.lifeAreaId),
      link: link,
      mode: FocusMode.fromWire(row.mode),
      preset: row.preset,
      plannedDurationSec: row.plannedDurationSec,
      status: FocusSessionStatus.fromWire(row.status),
      wallAnchorUtc: row.wallAnchorUtc,
      monotonicAnchorMicros: row.monotonicAnchorMicros,
      bootSessionId: row.bootSessionId,
      accumulatedDurationSec: row.accumulatedDurationSec,
      startedAtUtc: row.startedAtUtc,
      endedAtUtc: row.endedAtUtc,
      revision: row.revision,
      createdAtUtc: row.createdAtUtc,
      updatedAtUtc: row.updatedAtUtc,
      deletedAtUtc: row.deletedAtUtc,
    );
  }

  static FocusSessionsCompanion sessionToInsert(FocusSession session) =>
      FocusSessionsCompanion.insert(
        id: session.id.value,
        profileId: session.profileId.value,
        lifeAreaId: session.lifeAreaId.value,
        linkTargetType: Value<String?>(session.link?.type.wire),
        linkTargetId: Value<String?>(session.link?.targetId),
        mode: session.mode.wire,
        preset: Value<String?>(session.preset),
        plannedDurationSec: Value<int?>(session.plannedDurationSec),
        status: session.status.wire,
        wallAnchorUtc: session.wallAnchorUtc,
        monotonicAnchorMicros: session.monotonicAnchorMicros,
        bootSessionId: session.bootSessionId,
        accumulatedDurationSec: session.accumulatedDurationSec,
        startedAtUtc: session.startedAtUtc,
        endedAtUtc: Value<int?>(session.endedAtUtc),
        revision: Value<int>(session.revision),
        createdAtUtc: session.createdAtUtc,
        updatedAtUtc: session.updatedAtUtc,
        deletedAtUtc: Value<int?>(session.deletedAtUtc),
      );

  /// A full mutable-column update companion for an existing session.
  static FocusSessionsCompanion sessionToUpdate(FocusSession session) =>
      FocusSessionsCompanion(
        status: Value<String>(session.status.wire),
        wallAnchorUtc: Value<int>(session.wallAnchorUtc),
        monotonicAnchorMicros: Value<int>(session.monotonicAnchorMicros),
        bootSessionId: Value<String>(session.bootSessionId),
        accumulatedDurationSec: Value<int>(session.accumulatedDurationSec),
        endedAtUtc: Value<int?>(session.endedAtUtc),
        revision: Value<int>(session.revision),
        updatedAtUtc: Value<int>(session.updatedAtUtc),
        deletedAtUtc: Value<int?>(session.deletedAtUtc),
      );

  // ---- focus_intervals ----------------------------------------------------

  static FocusInterval intervalFromRow(FocusIntervalRow row) => FocusInterval(
    id: row.id,
    profileId: row.profileId,
    sessionId: row.sessionId,
    kind: FocusIntervalKind.fromWire(row.intervalKind),
    startedAtUtc: row.startedAtUtc,
    endedAtUtc: row.endedAtUtc,
    monotonicStartMicros: row.monotonicStartMicros,
    monotonicEndMicros: row.monotonicEndMicros,
    bootSessionId: row.bootSessionId,
    createdAtUtc: row.createdAtUtc,
  );

  static FocusIntervalsCompanion intervalToInsert(FocusInterval interval) =>
      FocusIntervalsCompanion.insert(
        id: interval.id,
        profileId: interval.profileId,
        sessionId: interval.sessionId,
        intervalKind: interval.kind.wire,
        startedAtUtc: interval.startedAtUtc,
        endedAtUtc: Value<int?>(interval.endedAtUtc),
        monotonicStartMicros: Value<int?>(interval.monotonicStartMicros),
        monotonicEndMicros: Value<int?>(interval.monotonicEndMicros),
        bootSessionId: interval.bootSessionId,
        createdAtUtc: interval.createdAtUtc,
      );

  // ---- focus_events -------------------------------------------------------

  static FocusEvent eventFromRow(FocusEventRow row) => FocusEvent(
    id: row.id,
    profileId: row.profileId,
    sessionId: row.sessionId,
    kind: FocusEventKind.fromWire(row.eventKind),
    commandId: row.commandId,
    wallAtUtc: row.wallAtUtc,
    monotonicMicros: row.monotonicMicros,
    bootSessionId: row.bootSessionId,
    payload: row.payload,
    payloadVersion: row.payloadVersion,
    occurredAtUtc: row.occurredAtUtc,
    supersedesId: row.supersedesId,
  );

  static FocusEventsCompanion eventToInsert(FocusEvent event) =>
      FocusEventsCompanion.insert(
        id: event.id,
        profileId: event.profileId,
        sessionId: event.sessionId,
        commandId: Value<String?>(event.commandId),
        eventKind: event.kind.wire,
        wallAtUtc: event.wallAtUtc,
        monotonicMicros: Value<int?>(event.monotonicMicros),
        bootSessionId: event.bootSessionId,
        payload: Value<String?>(event.payload),
        payloadVersion: event.payloadVersion,
        occurredAtUtc: event.occurredAtUtc,
        supersedesId: Value<String?>(event.supersedesId),
      );
}
