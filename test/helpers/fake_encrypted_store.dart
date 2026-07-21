import 'dart:typed_data';

import 'package:forge/app/infrastructure/database/encrypted_store.dart';
import 'package:forge/core/application/unit_of_work.dart';

import 'database_harness.dart';

/// In-memory [EncryptedStore] for runtime lifecycle tests.
final class FakeEncryptedStore implements EncryptedStore {
  FakeEncryptedStore({
    required this.unitOfWork,
    this.verification = const StoreVerification.allPassed(),
  });

  @override
  final UnitOfWork unitOfWork;

  @override
  final StoreVerification verification;

  bool _disposed = false;
  bool get isDisposed => _disposed;

  @override
  Future<void> dispose() async {
    _disposed = true;
  }
}

/// Configurable [EncryptedStoreOpener] test double.
///
/// It captures the key bytes exposed by the borrowed lease (proving the runtime
/// delivered the released key) and can simulate open failures or failing
/// verification without any native cipher.
final class FakeEncryptedStoreOpener implements EncryptedStoreOpener {
  FakeEncryptedStoreOpener({
    this.verification = const StoreVerification.allPassed(),
    this.failOpen = false,
  });

  final StoreVerification verification;
  final bool failOpen;

  int openCount = 0;
  EncryptedStoreRequest? lastRequest;
  Uint8List? observedKeyBytes;
  bool leaseWasLiveAtOpen = false;

  @override
  Future<EncryptedStore> open(EncryptedStoreRequest request) async {
    openCount += 1;
    lastRequest = request;
    leaseWasLiveAtOpen = !request.keyLease.isDisposed;
    observedKeyBytes = request.keyLease.copyBytes();
    if (failOpen) {
      throw const FormatException('simulated open failure');
    }
    return FakeEncryptedStore(
      unitOfWork: FakeUnitOfWork(repositories: const <Type, Object>{}),
      verification: verification,
    );
  }
}
