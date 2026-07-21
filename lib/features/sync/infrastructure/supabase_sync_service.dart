/// The runtime orchestrator that ties the GoTrue auth adapter, the secure
/// token store, the remote-profile gateway, and the push/pull engine into the
/// actions the "Account & sync" UI drives (R-SYNC-001, R-SYNC-005).
///
/// It is constructed at the composition root ONLY when a backend is configured
/// (two dart-defines present). It exposes a [ValueListenable] of [SyncStatus]
/// the UI observes, plus [signInWithPassword], [signOut] and [syncNow]. Sync is
/// always additive — the local-first store works unchanged whether or not this
/// service exists.
library;

// Named constructor parameters bind to private fields; the initializing-formal
// form would leak underscored parameter names into the public API.
// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/features/sync/application/auth/auth_ports.dart';
import 'package:forge/features/sync/domain/auth/auth_tokens.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';
import 'package:forge/features/sync/domain/sync_state.dart';
import 'package:forge/features/sync/infrastructure/gotrue_auth_client.dart';
import 'package:forge/features/sync/infrastructure/supabase_remote_profile_gateway.dart';
import 'package:forge/features/sync/infrastructure/supabase_sync_engine.dart';
import 'package:forge/features/sync/infrastructure/supabase_sync_transport.dart';

/// Orchestrates sign-in, sign-out, and manual sync for one linked profile.
final class SupabaseSyncService {
  SupabaseSyncService({
    required GoTrueAuthClient auth,
    required SecureTokenStore tokenStore,
    required MutableSupabaseSyncSession session,
    required SupabaseRemoteProfileGateway profileGateway,
    required SupabaseSyncEngine engine,
    required Clock clock,
    required String backendId,
    required RemoteProfileId remoteProfileId,
  }) : _auth = auth,
       _tokenStore = tokenStore,
       _session = session,
       _profileGateway = profileGateway,
       _engine = engine,
       _clock = clock,
       _backendId = backendId,
       _remoteProfileId = remoteProfileId;

  final GoTrueAuthClient _auth;
  final SecureTokenStore _tokenStore;
  final MutableSupabaseSyncSession _session;
  final SupabaseRemoteProfileGateway _profileGateway;
  final SupabaseSyncEngine _engine;
  final Clock _clock;
  final String _backendId;

  /// The remote profile this device links to. For a first device this adopts
  /// the local profile id (R-SYNC-001); the account still owns it server-side
  /// via auth.uid(). Fixed for the life of the service so the engine's identity
  /// translation is stable.
  final RemoteProfileId _remoteProfileId;

  final ValueNotifier<SyncStatus> _status = ValueNotifier<SyncStatus>(
    SyncStatus.signedOut(),
  );

  /// The observable sync status the UI renders (R-SYNC-005).
  ValueListenable<SyncStatus> get status => _status;

  /// The configured backend id (shown in the trust disclosure / diagnostics).
  String get backendId => _backendId;

  /// Restores a persisted session on startup: if durable tokens exist, adopt
  /// them and move to `linked`; otherwise stay signed out.
  Future<void> restore() async {
    final AuthTokens? tokens = await _tokenStore.readTokens();
    if (tokens == null) {
      _status.value = SyncStatus.signedOut();
      return;
    }
    _session.accessToken = tokens.accessToken.reveal();
    _session.remoteProfileId = _remoteProfileId;
    _status.value = _status.value.copyWith(linkState: SyncLinkState.linked);
  }

  /// Signs in with email + password, persists the session behind the secure
  /// token store, provisions the account's remote profile, and links the
  /// device. On success the status becomes `linked`.
  Future<Result<void>> signInWithPassword({
    required String email,
    required String password,
  }) async {
    _status.value = _status.value.copyWith(
      linkState: SyncLinkState.authenticating,
      error: SyncErrorKind.none,
      currentErrorCode: null,
    );
    try {
      final GoTrueSession gotrue = await _auth.signInWithPassword(
        email: email,
        password: password,
      );
      await _adoptSession(gotrue);
      return const _Ok();
    } on OAuthGatewayException catch (error) {
      return _fail(
        SyncErrorKind.authentication,
        'sync.auth.${error.kind.name}',
      );
    } on SupabaseSyncTransportException catch (error) {
      return _fail(_errorKindFor(error), 'sync.transport.${error.kind.name}');
    } on Object catch (error) {
      return _fail(SyncErrorKind.unexpected, error.runtimeType.toString());
    }
  }

  /// Signs up a new account with email + password (used where sign-up is
  /// allowed), then adopts the session exactly like sign-in.
  Future<Result<void>> signUpWithPassword({
    required String email,
    required String password,
  }) async {
    _status.value = _status.value.copyWith(
      linkState: SyncLinkState.authenticating,
    );
    try {
      final GoTrueSession gotrue = await _auth.signUpWithPassword(
        email: email,
        password: password,
      );
      await _adoptSession(gotrue);
      return const _Ok();
    } on OAuthGatewayException catch (error) {
      return _fail(
        SyncErrorKind.authentication,
        'sync.auth.${error.kind.name}',
      );
    } on Object catch (error) {
      return _fail(SyncErrorKind.unexpected, error.runtimeType.toString());
    }
  }

  Future<void> _adoptSession(GoTrueSession gotrue) async {
    // Persist the durable session behind the secure token store (never the DB).
    final AuthTokens? existing = await _tokenStore.readTokens();
    await _tokenStore.compareAndSwapTokens(
      expectedGeneration:
          existing?.rotationGeneration ?? kNoStoredTokensGeneration,
      next: AuthTokens(
        accessToken: gotrue.accessToken,
        refreshToken: gotrue.refreshToken,
        tokenType: gotrue.tokenType,
        accessTokenExpiresAtUtcMicros:
            _clock.utcNow().microsecondsSinceEpoch +
            gotrue.expiresIn.inMicroseconds,
        accountFingerprint: gotrue.accountFingerprint,
      ),
    );
    _session.accessToken = gotrue.accessToken.reveal();
    _session.remoteProfileId = _remoteProfileId;
    // Provision (idempotently) the account's remote profile so push/pull work.
    // The remote profile adopts this device's remote profile id (R-SYNC-001).
    await _profileGateway.ensureRemoteProfile(_remoteProfileId);
    _status.value = _status.value.copyWith(
      linkState: SyncLinkState.linked,
      error: SyncErrorKind.none,
      currentErrorCode: null,
    );
  }

  /// Runs a manual push+pull cycle (R-SYNC-005 "Sync now").
  Future<Result<SyncRunReport>> syncNow() async {
    if (!_status.value.linkState.canExchange) {
      return _failTyped<SyncRunReport>(
        SyncErrorKind.authentication,
        'sync.not_linked',
      );
    }
    try {
      final SyncRunReport report = await _engine.syncNow();
      _status.value = _status.value.copyWith(
        error: report.needsBootstrap
            ? SyncErrorKind.retentionOrEpochReset
            : SyncErrorKind.none,
        currentErrorCode: null,
        lastSuccessAtUtcMicros: _clock.utcNow().microsecondsSinceEpoch,
        pendingOperationCount: 0,
      );
      return Success<SyncRunReport>(report);
    } on SupabaseSyncTransportException catch (error) {
      return _failTyped<SyncRunReport>(
        _errorKindFor(error),
        'sync.transport.${error.kind.name}',
      );
    } on Object catch (error) {
      return _failTyped<SyncRunReport>(
        SyncErrorKind.unexpected,
        error.runtimeType.toString(),
      );
    }
  }

  /// Signs out: best-effort server revocation, clears the durable tokens, and
  /// returns to the signed-out state. Local data is never deleted.
  Future<void> signOut() async {
    final AuthTokens? tokens = await _tokenStore.readTokens();
    final String? token = _session.accessToken;
    if (token != null) {
      try {
        await _auth.signOut(token);
      } on Object {
        // Revocation is best-effort; local tokens are cleared regardless.
      }
    }
    if (tokens != null) {
      await _tokenStore.compareAndSwapTokens(
        expectedGeneration: tokens.rotationGeneration,
        next: null,
      );
    }
    _session.accessToken = null;
    _session.remoteProfileId = null;
    _status.value = SyncStatus.signedOut();
  }

  void dispose() => _status.dispose();

  SyncErrorKind _errorKindFor(SupabaseSyncTransportException error) =>
      switch (error.kind) {
        SyncTransportErrorKind.authentication => SyncErrorKind.authentication,
        SyncTransportErrorKind.network => SyncErrorKind.network,
        SyncTransportErrorKind.server => SyncErrorKind.server,
        SyncTransportErrorKind.protocol => SyncErrorKind.unexpected,
      };

  Result<void> _fail(SyncErrorKind kind, String code) {
    _status.value = _status.value.copyWith(
      linkState: kind == SyncErrorKind.authentication
          ? SyncLinkState.signedOut
          : _status.value.linkState,
      error: kind,
      currentErrorCode: code,
    );
    return _Err(code);
  }

  Result<T> _failTyped<T>(SyncErrorKind kind, String code) {
    _status.value = _status.value.copyWith(error: kind, currentErrorCode: code);
    return _ErrTyped<T>(code);
  }
}

/// A tiny result type local to the sync service so the UI can branch on
/// success/failure without leaking transport detail.
sealed class Result<T> {
  const Result();

  bool get isSuccess => this is Success<T>;

  String? get errorCode => switch (this) {
    Success<T>() => null,
    _ErrTyped<T>(code: final String code) => code,
  };
}

final class Success<T> extends Result<T> {
  const Success(this.value);
  final T value;
}

final class _ErrTyped<T> extends Result<T> {
  const _ErrTyped(this.code);
  final String code;
}

/// A void success.
final class _Ok extends Success<void> {
  const _Ok() : super(null);
}

/// A void failure.
final class _Err extends _ErrTyped<void> {
  const _Err(super.code);
}
