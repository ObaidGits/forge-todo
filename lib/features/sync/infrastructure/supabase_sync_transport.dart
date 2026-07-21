/// The Supabase PostgREST implementation of [SyncTransport] (R-SYNC-003,
/// R-SYNC-007; design.md §9, data-model.md §6).
///
/// This is the only component that speaks the protocol-v2 wire. It POSTs to the
/// reviewed `forge.push` / `forge.pull` RPCs at `/rest/v1/rpc/<fn>` selecting
/// the `forge` schema with the `Content-Profile` request header, authenticating
/// with the public `apikey` and the account's `Authorization: Bearer <access
/// token>`. It serializes a [PushBatch] to the exact RPC JSON the SQL functions
/// consume and parses [PushResponse] / [PullPage] from their jsonb results,
/// mapping stale-epoch and epoch-mismatch outcomes to the typed results the
/// contract expects (rather than throwing).
///
/// Transport is TLS-protected but NOT end-to-end encrypted (see
/// [SyncTrustDisclosure]); the composition root discloses this before linking.
/// All `package:http` usage stays behind this infrastructure layer.
library;

// Named constructor parameters bind to private fields; the initializing-formal
// form would leak underscored parameter names into the public API.
// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:forge/features/sync/application/sync_server_contract.dart';
import 'package:forge/features/sync/application/sync_transport.dart';
import 'package:forge/features/sync/domain/field_version.dart';
import 'package:forge/features/sync/domain/remote_change.dart';
import 'package:forge/features/sync/domain/semantic_group.dart';
import 'package:forge/features/sync/domain/sync_cursor.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';
import 'package:http/http.dart' as http;

/// A stable classification of a transport failure. Never leaks tokens or raw
/// server bodies.
enum SyncTransportErrorKind {
  /// Connectivity/TLS failure; retryable.
  network,

  /// The access token was missing, rejected, or expired (HTTP 401/403). The
  /// caller refreshes/reauthenticates before retrying.
  authentication,

  /// The backend returned a server-side error (HTTP 5xx); retryable.
  server,

  /// The request was rejected as malformed or over-limit (HTTP 4xx other than
  /// 401/403), or the response could not be parsed; not retryable as-is.
  protocol,
}

/// Raised by [SupabaseSyncTransport] for out-of-band failures. In-band protocol
/// outcomes (stale epoch on push, epoch mismatch on pull) are returned as typed
/// results, never as exceptions.
final class SupabaseSyncTransportException implements Exception {
  const SupabaseSyncTransportException(this.kind, {this.statusCode, this.hint});

  final SyncTransportErrorKind kind;
  final int? statusCode;

  /// A short, redacted hint safe to log; never contains a token or full body.
  final String? hint;

  bool get retryable =>
      kind == SyncTransportErrorKind.network ||
      kind == SyncTransportErrorKind.server;

  @override
  String toString() =>
      'SupabaseSyncTransportException(${kind.name}, status=$statusCode)';
}

/// The minimal session state the transport needs on every call: the current
/// account access token and the linked remote profile the pull cursor belongs
/// to. Both are null when signed out / unlinked. Supplied by the composition
/// root so the transport stays free of auth/link storage concerns.
abstract interface class SupabaseSyncSession {
  /// The current account access token, or null when signed out.
  String? get accessToken;

  /// The linked remote profile a pull reads from, or null when unlinked.
  RemoteProfileId? get remoteProfileId;
}

/// A trivial mutable [SupabaseSyncSession] the composition root updates as the
/// auth/link state changes.
final class MutableSupabaseSyncSession implements SupabaseSyncSession {
  MutableSupabaseSyncSession({this.accessToken, this.remoteProfileId});

  @override
  String? accessToken;

  @override
  RemoteProfileId? remoteProfileId;
}

/// The Supabase PostgREST [SyncTransport].
final class SupabaseSyncTransport implements SyncTransport {
  SupabaseSyncTransport({
    required Uri baseUrl,
    required String anonKey,
    required SupabaseSyncSession session,
    http.Client? client,
    String schema = _forgeSchema,
  }) : _baseUrl = baseUrl,
       _anonKey = anonKey,
       _session = session,
       _client = client ?? http.Client(),
       _schema = schema;

  static const String _forgeSchema = 'forge';

  final Uri _baseUrl;
  final String _anonKey;
  final SupabaseSyncSession _session;
  final http.Client _client;
  final String _schema;

  @override
  Future<PushResponse> push(PushBatch batch) async {
    final Map<String, Object?> body = <String, Object?>{
      'p_remote_profile_id': batch.remoteProfileId.value,
      'p_device_id': batch.deviceId,
      'p_snapshot_epoch': batch.snapshotEpoch.value,
      'p_groups': batch.groups.map(_encodeGroup).toList(growable: false),
    };
    final Map<String, Object?> json = await _rpc(SyncServerRpc.push, body);
    return _decodePushResponse(json);
  }

  @override
  Future<PullPage> pull(SyncCursor cursor) async {
    final RemoteProfileId? remote = _session.remoteProfileId;
    if (remote == null) {
      throw const SupabaseSyncTransportException(
        SyncTransportErrorKind.authentication,
        hint: 'pull requires a linked remote profile',
      );
    }
    final Map<String, Object?> body = <String, Object?>{
      'p_remote_profile_id': remote.value,
      'p_snapshot_epoch': cursor.epoch.value,
      'p_after_server_seq': cursor.serverSeq.value,
      'p_limit': SyncProtocolLimits.maxChangesPerPullPage,
    };
    final Map<String, Object?> json = await _rpc(SyncServerRpc.pull, body);
    return _decodePullPage(json, cursor, remote);
  }

  // --- Wire encoding -------------------------------------------------------

  Map<String, Object?> _encodeGroup(SemanticGroup group) => <String, Object?>{
    'group_id': group.groupId,
    'operations': group.operations
        .map(_encodeOperation)
        .toList(growable: false),
  };

  Map<String, Object?> _encodeOperation(SyncOperation op) {
    final Map<String, Object?> encoded = <String, Object?>{
      'operation_id': op.operationId,
      'index': op.index,
      'entity_type': op.entityType,
      'entity_id': op.entityId,
      'kind': op.kind.wire,
      'payload': op.payload,
    };
    if (op.changedFields.isNotEmpty) {
      encoded['changed_fields'] = op.changedFields;
    }
    final String? parent = op.parentEntityId;
    if (parent != null) {
      encoded['parent_entity_id'] = parent;
    }
    final FieldVersionMap? base = op.baseFieldVersions;
    if (base != null && !base.isEmpty) {
      encoded['base_field_versions'] = <String, Object?>{
        for (final String field in base.fields) field: base[field]!.version,
      };
    }
    return encoded;
  }

  // --- Wire decoding -------------------------------------------------------

  PushResponse _decodePushResponse(Map<String, Object?> json) {
    final int serverEpoch = _asInt(json['server_epoch'], 'server_epoch');
    final List<Object?> rawResults = _asList(json['results'], 'results');
    final List<SemanticGroupResult> results = rawResults
        .map((Object? raw) => _decodeGroupResult(_asMap(raw, 'result')))
        .toList(growable: false);
    return PushResponse(
      serverEpoch: SnapshotEpoch(serverEpoch),
      results: results,
    );
  }

  SemanticGroupResult _decodeGroupResult(Map<String, Object?> json) {
    return SemanticGroupResult(
      groupId: _asString(json['group_id'], 'group_id'),
      outcome: SyncGroupOutcomeWire.fromWire(
        _asString(json['outcome'], 'outcome'),
      ),
      conflictArtifactId: json['conflict_artifact_id'] as String?,
      rejectionReason: json['rejection_reason'] as String?,
    );
  }

  PullPage _decodePullPage(
    Map<String, Object?> json,
    SyncCursor cursor,
    RemoteProfileId remote,
  ) {
    // Epoch mismatch: the server signals the client must bootstrap onto its
    // current epoch. Represent it as an empty page carrying the server's epoch,
    // so the cursor's own decision routes it to bootstrap (data-model.md §6).
    if (json['epoch_mismatch'] == true) {
      final int serverEpoch = _asInt(json['server_epoch'], 'server_epoch');
      return PullPage(
        remoteProfileId: remote,
        epoch: SnapshotEpoch(serverEpoch),
        fromSeq: cursor.serverSeq,
        toSeq: cursor.serverSeq,
        changes: const <RemoteChange>[],
        nextCursor: SyncCursor(
          epoch: SnapshotEpoch(serverEpoch),
          serverSeq: ServerSeq.zero,
        ),
      );
    }

    final int epoch = _asInt(json['snapshot_epoch'], 'snapshot_epoch');
    final int fromSeq = _asInt(json['from_server_seq'], 'from_server_seq');
    final int toSeq = _asInt(json['to_server_seq'], 'to_server_seq');
    final List<Object?> rawChanges = _asList(json['changes'], 'changes');
    final List<RemoteChange> changes = rawChanges
        .map((Object? raw) => _decodeChange(_asMap(raw, 'change')))
        .toList(growable: false);
    final Map<String, Object?> nextCursorJson = _asMap(
      json['next_cursor'],
      'next_cursor',
    );
    final SyncCursor nextCursor = SyncCursor(
      epoch: SnapshotEpoch(
        _asInt(nextCursorJson['epoch'], 'next_cursor.epoch'),
      ),
      serverSeq: ServerSeq(
        _asInt(nextCursorJson['server_seq'], 'next_cursor.server_seq'),
      ),
    );
    return PullPage(
      remoteProfileId: remote,
      epoch: SnapshotEpoch(epoch),
      fromSeq: ServerSeq(fromSeq),
      toSeq: ServerSeq(toSeq),
      changes: changes,
      nextCursor: nextCursor,
      hasMore: json['has_more'] == true,
    );
  }

  RemoteChange _decodeChange(Map<String, Object?> json) {
    return RemoteChange(
      changeId: _asString(json['change_id'], 'change_id'),
      entityType: _asString(json['entity_type'], 'entity_type'),
      entityId: _asString(json['entity_id'], 'entity_id'),
      kind: SyncOperationKind.fromWire(_asString(json['kind'], 'kind')),
      serverSeq: ServerSeq(_asInt(json['server_seq'], 'server_seq')),
      serverVersion: _asInt(json['server_version'], 'server_version'),
      payload: _payloadOf(json['payload']),
      parentEntityId: json['parent_entity_id'] as String?,
      fieldVersions: _decodeFieldVersions(json['field_versions']),
      tombstone: json['tombstone'] == true,
    );
  }

  Map<String, Object?> _payloadOf(Object? raw) {
    if (raw == null) {
      return <String, Object?>{};
    }
    return _asMap(raw, 'payload');
  }

  FieldVersionMap? _decodeFieldVersions(Object? raw) {
    if (raw is! Map<String, Object?>) {
      return null;
    }
    final Map<String, FieldVersion> versions = <String, FieldVersion>{};
    for (final MapEntry<String, Object?> entry in raw.entries) {
      final Map<String, Object?> fv = _asMap(entry.value, 'field_version');
      versions[entry.key] = FieldVersion(
        version: _asInt(fv['version'], 'field_version.version'),
        lastOperationId: _asString(
          fv['last_operation_id'],
          'field_version.last_operation_id',
        ),
      );
    }
    return FieldVersionMap(versions);
  }

  // --- HTTP ----------------------------------------------------------------

  Future<Map<String, Object?>> _rpc(
    String rpcName,
    Map<String, Object?> body,
  ) async {
    // The RPC names are `forge.push` / `forge.pull`; PostgREST addresses the
    // function by its bare name under the schema selected by Content-Profile.
    final String fn = rpcName.contains('.') ? rpcName.split('.').last : rpcName;
    final Uri uri = _baseUrl.resolve('/rest/v1/rpc/$fn');
    final String? token = _session.accessToken;
    if (token == null || token.isEmpty) {
      throw const SupabaseSyncTransportException(
        SyncTransportErrorKind.authentication,
        hint: 'no access token',
      );
    }
    final http.Response response;
    try {
      response = await _client.post(
        uri,
        headers: <String, String>{
          'apikey': _anonKey,
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          // RPC is a POST, so the target schema is selected with
          // Content-Profile (Accept-Profile only affects GET reads).
          'Content-Profile': _schema,
          'Accept-Profile': _schema,
        },
        body: jsonEncode(body),
      );
    } on Object catch (error) {
      throw SupabaseSyncTransportException(
        SyncTransportErrorKind.network,
        hint: error.runtimeType.toString(),
      );
    }
    return _parseResponse(response);
  }

  Map<String, Object?> _parseResponse(http.Response response) {
    final int status = response.statusCode;
    if (status == 401 || status == 403) {
      throw SupabaseSyncTransportException(
        SyncTransportErrorKind.authentication,
        statusCode: status,
      );
    }
    if (status >= 500) {
      throw SupabaseSyncTransportException(
        SyncTransportErrorKind.server,
        statusCode: status,
      );
    }
    if (status < 200 || status >= 300) {
      throw SupabaseSyncTransportException(
        SyncTransportErrorKind.protocol,
        statusCode: status,
        hint: _errorHint(response.body),
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const SupabaseSyncTransportException(
        SyncTransportErrorKind.protocol,
        hint: 'malformed JSON body',
      );
    }
    return _asMap(decoded, 'response');
  }

  /// Extracts a short redacted hint (PostgREST error `code`/`message`) without
  /// echoing the whole body.
  String? _errorHint(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) {
        final Object? code = decoded['code'];
        if (code is String) {
          return 'code=$code';
        }
      }
    } on FormatException {
      // fall through
    }
    return null;
  }

  // --- Parsing helpers -----------------------------------------------------

  static Map<String, Object?> _asMap(Object? value, String field) {
    if (value is Map<String, Object?>) {
      return value;
    }
    if (value is Map) {
      return value.map(
        (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
      );
    }
    throw SupabaseSyncTransportException(
      SyncTransportErrorKind.protocol,
      hint: 'expected object for $field',
    );
  }

  static List<Object?> _asList(Object? value, String field) {
    if (value is List) {
      return value;
    }
    throw SupabaseSyncTransportException(
      SyncTransportErrorKind.protocol,
      hint: 'expected array for $field',
    );
  }

  static int _asInt(Object? value, String field) {
    if (value is int) {
      return value;
    }
    if (value is String) {
      final int? parsed = int.tryParse(value);
      if (parsed != null) {
        return parsed;
      }
    }
    throw SupabaseSyncTransportException(
      SyncTransportErrorKind.protocol,
      hint: 'expected integer for $field',
    );
  }

  static String _asString(Object? value, String field) {
    if (value is String) {
      return value;
    }
    if (value is int) {
      return value.toString();
    }
    throw SupabaseSyncTransportException(
      SyncTransportErrorKind.protocol,
      hint: 'expected string for $field',
    );
  }
}
