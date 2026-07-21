import 'dart:convert';
import 'dart:io';

import 'package:forge/core/database/runtime.dart';

/// Immutable on-disk description of a held writer lock.
///
/// The metadata is deliberately content-free: it only names the owning process
/// identity and lease timing so a later process can decide whether the lock is
/// live or stale. No user data is recorded here.
final class WriterLockMetadata {
  const WriterLockMetadata({
    required this.ownerToken,
    required this.pid,
    required this.bootSessionId,
    required this.acquiredAtUtc,
    required this.renewedAtUtc,
    required this.leaseTtl,
  });

  final String ownerToken;
  final int pid;
  final String bootSessionId;
  final DateTime acquiredAtUtc;
  final DateTime renewedAtUtc;
  final Duration leaseTtl;

  /// A lock is stale when the machine has rebooted since it was taken (the
  /// holder cannot still be running under a different boot session) or its
  /// lease has lapsed without renewal.
  bool isStaleFor({
    required DateTime now,
    required String currentBootSessionId,
  }) {
    if (bootSessionId != currentBootSessionId) {
      return true;
    }
    final Duration sinceRenewal = now.toUtc().difference(renewedAtUtc.toUtc());
    return sinceRenewal > leaseTtl;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'owner_token': ownerToken,
    'pid': pid,
    'boot_session_id': bootSessionId,
    'acquired_at_utc': acquiredAtUtc.toUtc().toIso8601String(),
    'renewed_at_utc': renewedAtUtc.toUtc().toIso8601String(),
    'lease_ttl_micros': leaseTtl.inMicroseconds,
  };

  static WriterLockMetadata? tryParse(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      return WriterLockMetadata(
        ownerToken: decoded['owner_token']! as String,
        pid: decoded['pid']! as int,
        bootSessionId: decoded['boot_session_id']! as String,
        acquiredAtUtc: DateTime.parse(decoded['acquired_at_utc']! as String),
        renewedAtUtc: DateTime.parse(decoded['renewed_at_utc']! as String),
        leaseTtl: Duration(microseconds: decoded['lease_ttl_micros']! as int),
      );
    } on Object {
      // A malformed or truncated lock file is treated as recoverable: it cannot
      // represent a live owner, so callers may steal it.
      return null;
    }
  }
}

/// Raised when a live, non-stale lock is held by a different process.
final class WriterLockUnavailable implements Exception {
  const WriterLockUnavailable(this.heldBy);

  final WriterLockMetadata heldBy;

  @override
  String toString() =>
      'WriterLockUnavailable(pid=${heldBy.pid}, boot=${heldBy.bootSessionId})';
}

/// A held exclusive writer lock. Ownership is released on [dispose].
final class WriterLockHandle implements AsyncResource {
  WriterLockHandle._(this._lock, this._metadata);

  final ProcessWriterLock _lock;
  WriterLockMetadata _metadata;
  bool _released = false;

  WriterLockMetadata get metadata => _metadata;
  bool get isReleased => _released;

  /// Atomically refreshes the lease so peers continue to see this lock as live.
  Future<void> renew() async {
    if (_released) {
      throw StateError('Cannot renew a released writer lock.');
    }
    _metadata = await _lock._renew(_metadata);
  }

  @override
  Future<void> dispose() async {
    if (_released) {
      return;
    }
    _released = true;
    await _lock._release(_metadata);
  }
}

typedef LockClock = DateTime Function();
typedef TokenFactory = String Function();

/// OS/process-level exclusive writer lock guarding a single database
/// generation directory.
///
/// Exactly one runtime may hold the lock. A second instance either observes a
/// live lock (and fails, so the UI can focus the existing instance or open
/// read-only) or recovers a stale lock left by a crashed/rebooted holder.
final class ProcessWriterLock {
  ProcessWriterLock({
    required this.lockFile,
    required this.pid,
    required this.bootSessionId,
    required this.now,
    required this.tokenFactory,
    this.leaseTtl = const Duration(seconds: 30),
  }) {
    if (leaseTtl <= Duration.zero) {
      throw ArgumentError.value(leaseTtl, 'leaseTtl', 'Must be positive.');
    }
  }

  final File lockFile;
  final int pid;
  final String bootSessionId;
  final LockClock now;
  final TokenFactory tokenFactory;
  final Duration leaseTtl;

  /// Attempts to acquire the lock.
  ///
  /// Throws [WriterLockUnavailable] when a live, non-stale lock is held by a
  /// different process.
  Future<WriterLockHandle> acquire() async {
    final WriterLockMetadata? existing = await _readExisting();
    if (existing != null &&
        !existing.isStaleFor(now: now(), currentBootSessionId: bootSessionId)) {
      throw WriterLockUnavailable(existing);
    }

    final DateTime nowUtc = now().toUtc();
    final WriterLockMetadata mine = WriterLockMetadata(
      ownerToken: tokenFactory(),
      pid: pid,
      bootSessionId: bootSessionId,
      acquiredAtUtc: nowUtc,
      renewedAtUtc: nowUtc,
      leaseTtl: leaseTtl,
    );
    await _writeAtomic(mine);

    // Confirm we won any race for a freshly-stolen or new lock file.
    final WriterLockMetadata? confirmed = await _readExisting();
    if (confirmed == null || confirmed.ownerToken != mine.ownerToken) {
      throw WriterLockUnavailable(confirmed ?? mine);
    }
    return WriterLockHandle._(this, mine);
  }

  Future<WriterLockMetadata> _renew(WriterLockMetadata current) async {
    final WriterLockMetadata? onDisk = await _readExisting();
    if (onDisk == null || onDisk.ownerToken != current.ownerToken) {
      throw const WriterLockLost();
    }
    final WriterLockMetadata renewed = WriterLockMetadata(
      ownerToken: current.ownerToken,
      pid: current.pid,
      bootSessionId: current.bootSessionId,
      acquiredAtUtc: current.acquiredAtUtc,
      renewedAtUtc: now().toUtc(),
      leaseTtl: current.leaseTtl,
    );
    await _writeAtomic(renewed);
    return renewed;
  }

  Future<void> _release(WriterLockMetadata current) async {
    final WriterLockMetadata? onDisk = await _readExisting();
    if (onDisk != null && onDisk.ownerToken == current.ownerToken) {
      try {
        await lockFile.delete();
      } on FileSystemException {
        // Already gone; releasing is idempotent.
      }
    }
  }

  Future<WriterLockMetadata?> _readExisting() async {
    if (!await lockFile.exists()) {
      return null;
    }
    try {
      return WriterLockMetadata.tryParse(await lockFile.readAsString());
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _writeAtomic(WriterLockMetadata metadata) async {
    await lockFile.parent.create(recursive: true);
    final File temp = File('${lockFile.path}.tmp-${metadata.ownerToken}');
    await temp.writeAsString(jsonEncode(metadata.toJson()), flush: true);
    await temp.rename(lockFile.path);
  }
}

/// Raised when a held lock is discovered to have been taken over by another
/// process (e.g. after an unexpected stale-recovery race).
final class WriterLockLost implements Exception {
  const WriterLockLost();

  @override
  String toString() => 'WriterLockLost()';
}
