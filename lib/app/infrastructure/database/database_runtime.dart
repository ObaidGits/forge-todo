import 'dart:async';
import 'dart:io' as io;

import 'package:forge/app/infrastructure/database/active_generation_pointer.dart';
import 'package:forge/app/infrastructure/database/encrypted_store.dart';
import 'package:forge/app/infrastructure/database/recovery_mode.dart';
import 'package:forge/app/infrastructure/database/writer_lock.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/security/key_vault.dart';
import 'package:forge/core/security/redacting_log.dart';

/// Filesystem layout for a runtime instance. The pointer and lock live outside
/// every generation directory so the active generation can be replaced without
/// disturbing them.
final class DatabaseRuntimePaths {
  const DatabaseRuntimePaths({
    required this.baseDirectory,
    this.pointerFileName = 'active_generation.json',
    this.lockFileName = 'forge.writer.lock',
    this.initialGenerationDirectoryName = 'generation-0001',
  });

  final String baseDirectory;
  final String pointerFileName;
  final String lockFileName;
  final String initialGenerationDirectoryName;

  String _join(String a, String b) => a.endsWith('/') ? '$a$b' : '$a/$b';

  io.File get pointerFile => io.File(_join(baseDirectory, pointerFileName));

  io.File get lockFile => io.File(_join(baseDirectory, lockFileName));

  String generationDirectory(String name) => _join(baseDirectory, name);
}

/// Raised for non-recoverable bootstrap conditions that are not Recovery Mode,
/// e.g. a fresh install whose key has not been provisioned yet.
final class DatabaseBootstrapException implements Exception {
  const DatabaseBootstrapException(this.message);

  final String message;

  @override
  String toString() => 'DatabaseBootstrapException($message)';
}

/// Raised when headless work cannot run because the runtime is unavailable
/// (Recovery Mode) or the writer lock is held by a live instance.
final class HeadlessRuntimeUnavailable implements Exception {
  const HeadlessRuntimeUnavailable(this.message);

  final String message;

  @override
  String toString() => 'HeadlessRuntimeUnavailable($message)';
}

/// Production, lifecycle-owning [DatabaseRuntime].
///
/// A runtime exclusively owns its writer lock, encrypted store, and active
/// generation. It is created by [ForgeDatabaseRuntimeFactory.open] and torn
/// down by [dispose], which releases the store then the lock deterministically.
final class ForgeDatabaseRuntime implements DatabaseRuntime {
  ForgeDatabaseRuntime._ready(
    this._generation,
    this._store,
    this._lock,
    this.onDispose,
  ) : _recovery = null,
      _state = DatabaseRuntimeState.ready;

  ForgeDatabaseRuntime._recovery(this._recovery, this.onDispose)
    : _generation = null,
      _store = null,
      _lock = null,
      _state = DatabaseRuntimeState.recoveryRequired;

  final DatabaseGeneration? _generation;
  final EncryptedStore? _store;
  final WriterLockHandle? _lock;
  final RecoveryModeInfo? _recovery;
  final Future<void> Function()? onDispose;

  DatabaseRuntimeState _state;

  @override
  DatabaseRuntimeState get state => _state;

  /// Recovery details when [state] is `recoveryRequired`, else null.
  RecoveryModeInfo? get recovery => _recovery;

  @override
  DatabaseGeneration get activeGeneration {
    final DatabaseGeneration? generation = _generation;
    if (generation == null) {
      throw StateError('No active generation in state $_state.');
    }
    return generation;
  }

  @override
  UnitOfWork get unitOfWork {
    final EncryptedStore? store = _store;
    if (store == null || _state != DatabaseRuntimeState.ready) {
      throw StateError('Unit of work is unavailable in state $_state.');
    }
    return store.unitOfWork;
  }

  /// Closes command admission for a maintenance operation (bootstrap, restore,
  /// migration). Reversible via [resume].
  void enterMaintenance() {
    if (_state != DatabaseRuntimeState.ready) {
      throw StateError('Cannot enter maintenance from $_state.');
    }
    _state = DatabaseRuntimeState.maintenance;
  }

  void resume() {
    if (_state != DatabaseRuntimeState.maintenance) {
      throw StateError('Cannot resume from $_state.');
    }
    _state = DatabaseRuntimeState.ready;
  }

  @override
  Future<void> dispose() async {
    if (_state == DatabaseRuntimeState.closed ||
        _state == DatabaseRuntimeState.closing) {
      return;
    }
    _state = DatabaseRuntimeState.closing;
    // Release inner resources before the lock so no writer can observe a
    // released lock while our store is still open.
    await _store?.dispose();
    await _lock?.dispose();
    await onDispose?.call();
    _state = DatabaseRuntimeState.closed;
  }
}

/// Opens the single process-wide [ForgeDatabaseRuntime].
final class ForgeDatabaseRuntimeFactory implements DatabaseRuntimeFactory {
  ForgeDatabaseRuntimeFactory({
    required this.paths,
    required this.keyVault,
    required this.opener,
    required this.clock,
    required this.monotonicClock,
    required this.idGenerator,
    required this.initialGeneration,
    this.logger,
    this.processId,
    this.leaseTtl = const Duration(seconds: 30),
  });

  final DatabaseRuntimePaths paths;
  final KeyVault keyVault;
  final EncryptedStoreOpener opener;
  final Clock clock;
  final MonotonicClock monotonicClock;
  final IdGenerator idGenerator;
  final DatabaseGeneration initialGeneration;
  final StructuredLogger? logger;
  final int? processId;
  final Duration leaseTtl;

  static const String _component = 'database.runtime';

  ActiveGenerationPointer get _pointer =>
      ActiveGenerationPointer(pointerFile: paths.pointerFile);

  ProcessWriterLock get _writerLock => ProcessWriterLock(
    lockFile: paths.lockFile,
    pid: processId ?? io.pid,
    bootSessionId: monotonicClock.bootSessionId(),
    now: clock.utcNow,
    tokenFactory: idGenerator.uuidV7,
    leaseTtl: leaseTtl,
  );

  @override
  Future<ForgeDatabaseRuntime> open() async {
    _log(LogLevel.info, 'bootstrap_start');

    // Step 1: resolve the active-generation pointer.
    final ActiveGenerationRecord? pointer;
    try {
      pointer = await _pointer.read();
    } on ActiveGenerationPointerCorrupt catch (error) {
      return _recovery(RecoveryReason.pointerCorrupt, detail: error.reason);
    }

    // Step 2: ask the vault to RELEASE (never replace) the key.
    final KeyLease lease;
    try {
      lease = await keyVault.release();
    } on Object catch (error) {
      final bool ciphertextExists =
          keyVault.encryptedStoreExists || pointer != null;
      if (ciphertextExists) {
        // R-SEC-001: existing ciphertext with an unavailable key is Recovery
        // Mode. It never mints a replacement key.
        return _recovery(
          RecoveryReason.keyUnavailable,
          detail: keyVault.state.name,
        );
      }
      // Fresh install with no provisioned key: provisioning is a KeyVault
      // responsibility, not a runtime reset.
      throw DatabaseBootstrapException(
        'Key release unavailable for fresh store: $error',
      );
    }

    // Step 3: acquire the exclusive writer lock. A live lock means another
    // instance owns the store; surface it so the UI can focus/read-only.
    final WriterLockHandle lock;
    try {
      lock = await _writerLock.acquire();
    } on Object {
      await lease.dispose();
      rethrow;
    }

    final bool freshStore = pointer == null;
    final DatabaseGeneration generation =
        pointer?.generation ?? initialGeneration;
    final String generationName =
        pointer?.directoryName ?? paths.initialGenerationDirectoryName;

    // Step 4: open and verify the encrypted store. The lease is borrowed only
    // for the open call and disposed immediately after.
    EncryptedStore store;
    try {
      store = await opener.open(
        EncryptedStoreRequest(
          generationDirectory: paths.generationDirectory(generationName),
          schemaVersion: generation.schemaVersion,
          keyLease: lease,
          expectFreshStore: freshStore,
        ),
      );
    } on Object catch (error) {
      await lease.dispose();
      await lock.dispose();
      return _recovery(
        RecoveryReason.openFailed,
        detail: error.runtimeType.toString(),
      );
    }
    await lease.dispose();

    if (!store.verification.passed) {
      final String? failure = store.verification.firstFailure;
      await store.dispose();
      await lock.dispose();
      return _recovery(RecoveryReason.verificationFailed, detail: failure);
    }

    // Step 5: for a fresh store, publish the pointer atomically only after the
    // store has verified. A crash before this leaves no dangling pointer.
    if (freshStore) {
      await _pointer.switchTo(
        ActiveGenerationRecord(
          generation: generation,
          directoryName: generationName,
        ),
      );
    }

    _log(LogLevel.info, 'bootstrap_ready');
    return ForgeDatabaseRuntime._ready(
      generation,
      store,
      lock,
      () async => _log(LogLevel.info, 'disposed'),
    );
  }

  /// Runs a bounded headless composition against a freshly opened runtime and
  /// disposes it deterministically, even on timeout.
  ///
  /// Headless callbacks (widgets, background reconcilers) acquire the same
  /// non-stale writer lock, do a small amount of work under [deadline], and
  /// release everything.
  Future<T> runHeadless<T>(
    FutureOr<T> Function(ForgeDatabaseRuntime runtime) action, {
    required Duration deadline,
  }) async {
    if (deadline <= Duration.zero) {
      throw ArgumentError.value(deadline, 'deadline', 'Must be positive.');
    }
    final ForgeDatabaseRuntime runtime = await open();
    if (runtime.state != DatabaseRuntimeState.ready) {
      final RecoveryModeInfo? recovery = runtime.recovery;
      await runtime.dispose();
      throw HeadlessRuntimeUnavailable(
        'Runtime not ready: ${recovery?.reason.name ?? runtime.state.name}',
      );
    }
    try {
      return await Future<T>.sync(() => action(runtime)).timeout(deadline);
    } finally {
      await runtime.dispose();
    }
  }

  ForgeDatabaseRuntime _recovery(RecoveryReason reason, {String? detail}) {
    _log(
      LogLevel.warning,
      'recovery_mode',
      attributes: <String, LogAttribute>{
        'reason': LogAttribute.operational(reason.name),
        if (detail != null) 'detail': LogAttribute.operational(detail),
      },
    );
    return ForgeDatabaseRuntime._recovery(
      RecoveryModeInfo(reason: reason, detail: detail),
      null,
    );
  }

  void _log(
    LogLevel level,
    String eventCode, {
    Map<String, LogAttribute> attributes = const <String, LogAttribute>{},
  }) {
    logger?.log(
      level: level,
      component: _component,
      eventCode: eventCode,
      attributes: attributes,
    );
  }
}
