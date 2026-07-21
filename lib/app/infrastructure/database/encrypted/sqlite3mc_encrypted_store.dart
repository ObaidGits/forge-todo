import 'dart:io' as io;
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:forge/app/infrastructure/database/encrypted_store.dart';
import 'package:forge/app/infrastructure/database/schema/forge_schema.dart';
import 'package:forge/app/infrastructure/database/transaction/drift_unit_of_work.dart';
import 'package:forge/core/application/unit_of_work.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Resolves the active profile id for the encrypted store's [UnitOfWork].
///
/// The store is opened before the active profile is known (a fresh store has no
/// profile yet; an existing store's active profile is read only after the key
/// decrypts it). Bootstrap binds the id via [ActiveProfileBinding.bind] once it
/// has resolved or provisioned the profile, and the unit of work then peeks the
/// per-profile commit sequence through this resolver (design.md §5).
final class ActiveProfileBinding {
  String? _profileId;

  bool get isBound => _profileId != null;

  void bind(String profileId) => _profileId = profileId;

  String resolve() {
    final String? id = _profileId;
    if (id == null) {
      throw StateError(
        'Active profile has not been bound to the encrypted store yet.',
      );
    }
    return id;
  }
}

/// Concrete [EncryptedStore] over a Drift [ForgeSchemaDatabase] whose executor
/// is an sqlite3mc-encrypted native SQLite connection.
///
/// The cipher key is applied with `PRAGMA key` on the raw connection before any
/// other access, and the raw connection is then wrapped by drift via
/// [NativeDatabase.opened] so the schema, migrations, and every repository run
/// against the encrypted pages (ADR-0001). The store never retains the key
/// bytes: they are copied from the borrowed lease, hex-encoded for the single
/// key pragma, and zeroized immediately.
final class Sqlite3mcEncryptedStore implements EncryptedStore {
  Sqlite3mcEncryptedStore._({
    required this.database,
    required this.verification,
    required ActiveProfileBinding binding,
    required Map<Type, RepositoryFactory> repositoryFactories,
  }) : _binding = binding,
       _unitOfWork = DriftUnitOfWork(
         database,
         activeProfileResolver: binding.resolve,
         repositoryFactories: repositoryFactories,
       );

  /// The opened schema database. Exposed so bootstrap can read/seed the profile
  /// and default Life Areas before binding the active profile (the composition
  /// root is the one place allowed to touch concrete infrastructure).
  final ForgeSchemaDatabase database;

  @override
  final StoreVerification verification;

  final ActiveProfileBinding _binding;
  final UnitOfWork _unitOfWork;

  /// Binds the active profile id used by [unitOfWork]'s commit-sequence peek.
  void bindActiveProfile(String profileId) => _binding.bind(profileId);

  @override
  UnitOfWork get unitOfWork => _unitOfWork;

  @override
  Future<void> dispose() => database.close();
}

/// Production [EncryptedStoreOpener] that opens one sqlite3mc-encrypted
/// generation store and runs the mandatory startup verification sequence.
///
/// A single opener instance is used per runtime open; it exposes [lastOpened]
/// so the bootstrap that owns it can reach the concrete store (its raw database
/// and profile binding) after [ForgeDatabaseRuntimeFactory.open] returns ready.
final class Sqlite3mcEncryptedStoreOpener implements EncryptedStoreOpener {
  Sqlite3mcEncryptedStoreOpener({
    required this.repositoryFactories,
    this.databaseFileName = 'forge.sqlite',
  });

  /// The full merged repository factory set (all feature DAOs) bound into every
  /// transaction of the opened store's unit of work.
  final Map<Type, RepositoryFactory> repositoryFactories;

  final String databaseFileName;

  Sqlite3mcEncryptedStore? _lastOpened;

  /// The most recently opened store, or null before the first successful open.
  Sqlite3mcEncryptedStore? get lastOpened => _lastOpened;

  @override
  Future<EncryptedStore> open(EncryptedStoreRequest request) async {
    final io.Directory directory = io.Directory(request.generationDirectory);
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    final io.File dbFile = io.File(
      '${directory.path}${io.Platform.pathSeparator}$databaseFileName',
    );

    // Copy the borrowed key, hex-encode it for the single key pragma, then wipe
    // the copy. The lease itself is disposed by the runtime after open returns.
    final Uint8List keyBytes = request.keyLease.copyBytes();
    final String keyHex = _toHex(keyBytes);
    keyBytes.fillRange(0, keyBytes.length, 0);

    final sqlite.Database raw = sqlite.sqlite3.open(dbFile.path);
    // Apply the cipher key BEFORE any other access so every page read/written
    // goes through the sqlite3mc cipher.
    raw.execute('PRAGMA key = "x\'$keyHex\'"');

    final StoreVerification verification = _verify(
      raw,
      expectFreshStore: request.expectFreshStore,
      schemaVersion: request.schemaVersion,
    );

    if (verification.passed) {
      // Encrypt the write-ahead log too. Only attempted once the key is proven
      // good; a wrong key throws here because WAL setup touches the header.
      try {
        raw.execute('PRAGMA journal_mode = WAL');
      } on sqlite.SqliteException {
        // Non-fatal: fall back to the default journal mode.
      }
    }

    // Wrap the already-keyed raw connection so drift's schema, migrations, and
    // repositories operate on the encrypted store.
    final ForgeSchemaDatabase database = ForgeSchemaDatabase(
      NativeDatabase.opened(raw),
    );

    final Sqlite3mcEncryptedStore store = Sqlite3mcEncryptedStore._(
      database: database,
      verification: verification,
      binding: ActiveProfileBinding(),
      repositoryFactories: repositoryFactories,
    );
    _lastOpened = store;
    return store;
  }

  /// Runs the startup verification sequence on the keyed raw connection.
  ///
  /// A wrong key never resets data: sqlite3mc fails to decrypt the header, the
  /// probe read throws, and this reports `cipherConfigured`/`sentinelAuthentic`
  /// as false so the runtime routes to non-destructive Recovery Mode
  /// (R-SEC-001).
  StoreVerification _verify(
    sqlite.Database raw, {
    required bool expectFreshStore,
    required int schemaVersion,
  }) {
    // The active cipher must be a real encryption cipher (sqlite3mc reports the
    // configured cipher name, e.g. `chacha20`), never `none`.
    bool cipherConfigured;
    try {
      final List<Object?> cipherRow = raw
          .select('PRAGMA cipher')
          .map((sqlite.Row row) => row.values.isEmpty ? null : row.values.first)
          .toList();
      final Object? cipher = cipherRow.isEmpty ? null : cipherRow.first;
      cipherConfigured =
          cipher != null &&
          cipher.toString().isNotEmpty &&
          cipher.toString() != 'none';
    } on sqlite.SqliteException {
      cipherConfigured = false;
    }

    if (expectFreshStore) {
      // A brand-new store has no prior sentinel to authenticate; the schema is
      // created by drift on first use. Only the cipher and physical integrity
      // are meaningful here.
      final bool integrityOk = _integrityOk(raw);
      return StoreVerification(
        cipherConfigured: cipherConfigured,
        sentinelAuthentic: true,
        schemaCompatible: true,
        integrityOk: integrityOk,
      );
    }

    // Existing ciphertext: prove the key decrypted a real database by reading
    // the catalog. A wrong/absent key throws here.
    bool sentinelAuthentic;
    try {
      raw.select('SELECT count(*) FROM sqlite_master');
      sentinelAuthentic = true;
    } on sqlite.SqliteException {
      // Wrong key (or corrupt ciphertext): the cipher is not correctly
      // configured for THIS store either.
      return const StoreVerification(
        cipherConfigured: false,
        sentinelAuthentic: false,
        schemaCompatible: false,
        integrityOk: false,
      );
    }

    // Drift tracks its schema version in `user_version`. A store from a newer
    // schema (user_version > our supported version) is a downgrade we refuse;
    // an older one is upgraded transactionally by the migration strategy.
    bool schemaCompatible;
    try {
      final int userVersion =
          raw.select('PRAGMA user_version').single.values.single as int;
      schemaCompatible = userVersion <= schemaVersion;
    } on sqlite.SqliteException {
      schemaCompatible = false;
    }

    return StoreVerification(
      cipherConfigured: cipherConfigured,
      sentinelAuthentic: sentinelAuthentic,
      schemaCompatible: schemaCompatible,
      integrityOk: _integrityOk(raw),
    );
  }

  bool _integrityOk(sqlite.Database raw) {
    try {
      final Object? result = raw
          .select('PRAGMA integrity_check')
          .single
          .values
          .single;
      return result == 'ok';
    } on sqlite.SqliteException {
      return false;
    }
  }

  static const String _hex = '0123456789abcdef';

  static String _toHex(Uint8List bytes) {
    final StringBuffer out = StringBuffer();
    for (final int byte in bytes) {
      out
        ..write(_hex[(byte >> 4) & 0x0f])
        ..write(_hex[byte & 0x0f]);
    }
    return out.toString();
  }
}
