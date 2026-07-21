import 'package:flutter_test/flutter_test.dart';
import 'package:forge/config/app_config.dart';

void main() {
  test('parses every supported environment and channel combination', () {
    for (final ForgeEnvironment environment in ForgeEnvironment.values) {
      for (final ReleaseChannel channel in ReleaseChannel.values) {
        final AppConfig config = AppConfig.fromValues(
          environment: environment.name,
          releaseChannel: channel.name,
          buildRevision: ' revision ',
        );

        expect(config.environment, environment);
        expect(config.releaseChannel, channel);
        expect(config.buildRevision, 'revision');
      }
    }
  });

  test('rejects unknown typed values', () {
    expect(
      () => AppConfig.fromValues(
        environment: 'preview',
        releaseChannel: 'nightly',
        buildRevision: 'abc123',
      ),
      throwsFormatException,
    );
  });

  test('requires production and a revision for release entry points', () {
    final AppConfig development = AppConfig.fromValues(
      environment: 'development',
      releaseChannel: 'nightly',
      buildRevision: 'abc123',
    );
    final AppConfig unversioned = AppConfig.fromValues(
      environment: 'production',
      releaseChannel: 'stable',
      buildRevision: 'unversioned',
    );

    expect(development.validateForRelease, throwsStateError);
    expect(unversioned.validateForRelease, throwsStateError);
  });
}
