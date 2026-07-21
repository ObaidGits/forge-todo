/// The client-facing remote-profile provisioning adapter (R-SYNC-001).
///
/// A first device brings its remote profile into existence by calling the
/// reviewed `forge.ensure_remote_profile` RPC (migration 0005), which derives
/// the owner from `auth.uid()` and adopts the supplied id (the creating
/// device's local profile id). The call is idempotent: a second device for the
/// same account gets back the existing profile unchanged.
///
/// This is the thin server seam the sign-in flow uses to establish the
/// `(local_profile, owner_user, remote_profile)` link. All `package:http` usage
/// stays behind infrastructure.
library;

// Named constructor parameters bind to private fields; the initializing-formal
// form would leak underscored parameter names into the public API.
// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:forge/features/sync/domain/sync_identity.dart';
import 'package:forge/features/sync/domain/sync_protocol.dart';
import 'package:forge/features/sync/infrastructure/supabase_sync_transport.dart';
import 'package:http/http.dart' as http;

/// The result of provisioning: the owner's remote profile id and its current
/// server snapshot epoch.
final class RemoteProfileProvision {
  const RemoteProfileProvision({
    required this.remoteProfileId,
    required this.ownerUserId,
    required this.snapshotEpoch,
    required this.created,
  });

  final RemoteProfileId remoteProfileId;
  final OwnerUserId ownerUserId;
  final SnapshotEpoch snapshotEpoch;

  /// True when this call created the profile; false when it already existed.
  final bool created;
}

/// Provisions and reads the caller's own remote profile over PostgREST.
final class SupabaseRemoteProfileGateway {
  SupabaseRemoteProfileGateway({
    required Uri baseUrl,
    required String anonKey,
    required SupabaseSyncSession session,
    http.Client? client,
    String schema = 'forge',
  }) : _baseUrl = baseUrl,
       _anonKey = anonKey,
       _session = session,
       _client = client ?? http.Client(),
       _schema = schema;

  final Uri _baseUrl;
  final String _anonKey;
  final SupabaseSyncSession _session;
  final http.Client _client;
  final String _schema;

  /// Creates (or idempotently re-reads) the caller's remote profile whose id
  /// adopts [remoteProfileId] (the creating device's local profile id).
  Future<RemoteProfileProvision> ensureRemoteProfile(
    RemoteProfileId remoteProfileId,
  ) async {
    final Map<String, Object?> json = await _rpc('ensure_remote_profile', {
      'p_remote_profile_id': remoteProfileId.value,
    });
    return RemoteProfileProvision(
      remoteProfileId: RemoteProfileId(
        json['remote_profile_id'] as String? ?? remoteProfileId.value,
      ),
      ownerUserId: OwnerUserId(json['owner_user_id'] as String),
      snapshotEpoch: SnapshotEpoch((json['snapshot_epoch'] as int?) ?? 0),
      created: json['created'] == true,
    );
  }

  Future<Map<String, Object?>> _rpc(
    String fn,
    Map<String, Object?> body,
  ) async {
    final String? token = _session.accessToken;
    if (token == null || token.isEmpty) {
      throw const SupabaseSyncTransportException(
        SyncTransportErrorKind.authentication,
        hint: 'no access token',
      );
    }
    final Uri uri = _baseUrl.resolve('/rest/v1/rpc/$fn');
    final http.Response response;
    try {
      response = await _client.post(
        uri,
        headers: <String, String>{
          'apikey': _anonKey,
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
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
      );
    }
    final Object? decoded = jsonDecode(response.body);
    if (decoded is Map) {
      return decoded.map(
        (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
      );
    }
    throw const SupabaseSyncTransportException(
      SyncTransportErrorKind.protocol,
      hint: 'expected object response',
    );
  }
}
