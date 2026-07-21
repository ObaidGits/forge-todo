enum ForgeEnvironment { development, test, production }

enum ReleaseChannel { nightly, beta, stable }

/// Typed, compile-time-only application configuration.
///
/// Values are supplied with `--dart-define-from-file`; no environment file is
/// bundled as an asset and no authorization secret belongs in this type.
final class AppConfig {
  const AppConfig({
    required this.environment,
    required this.releaseChannel,
    required this.buildRevision,
  });

  factory AppConfig.fromEnvironment() => AppConfig.fromValues(
    environment: const String.fromEnvironment(
      'FORGE_ENV',
      defaultValue: 'development',
    ),
    releaseChannel: const String.fromEnvironment(
      'FORGE_RELEASE_CHANNEL',
      defaultValue: 'nightly',
    ),
    buildRevision: const String.fromEnvironment(
      'FORGE_BUILD_REVISION',
      defaultValue: 'unversioned',
    ),
  );

  factory AppConfig.fromValues({
    required String environment,
    required String releaseChannel,
    required String buildRevision,
  }) {
    return AppConfig(
      environment: _parseEnum(
        name: 'FORGE_ENV',
        value: environment,
        values: ForgeEnvironment.values,
      ),
      releaseChannel: _parseEnum(
        name: 'FORGE_RELEASE_CHANNEL',
        value: releaseChannel,
        values: ReleaseChannel.values,
      ),
      buildRevision: buildRevision.trim(),
    );
  }

  final ForgeEnvironment environment;
  final ReleaseChannel releaseChannel;
  final String buildRevision;

  void validateForRelease() {
    if (environment != ForgeEnvironment.production) {
      throw StateError('Release builds require FORGE_ENV=production.');
    }
    if (buildRevision.isEmpty || buildRevision == 'unversioned') {
      throw StateError('Release builds require a source revision.');
    }
  }

  static T _parseEnum<T extends Enum>({
    required String name,
    required String value,
    required List<T> values,
  }) {
    final String normalized = value.trim();
    for (final T candidate in values) {
      if (candidate.name == normalized) {
        return candidate;
      }
    }
    final String allowed = values.map((T value) => value.name).join(', ');
    throw FormatException('$name must be one of: $allowed', value);
  }
}
