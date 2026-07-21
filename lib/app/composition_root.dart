import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/infrastructure/system_clock.dart';
import 'package:forge/config/app_config.dart';
import 'package:forge/core/database/runtime.dart';
import 'package:forge/core/diagnostics/local_diagnostics.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/security/redacting_log.dart';

final Provider<AppConfig> appConfigProvider = Provider<AppConfig>((Ref ref) {
  throw StateError('appConfigProvider must be overridden at the root.');
});

/// The lifecycle-owning encrypted database runtime factory.
///
/// The concrete factory is a platform composition of the writer lock,
/// active-generation pointer, KeyVault, and the encrypted-store opener. It must
/// be overridden at the root once a cipher provider is authorized (ADR-0001).
final Provider<DatabaseRuntimeFactory> databaseRuntimeFactoryProvider =
    Provider<DatabaseRuntimeFactory>((Ref ref) {
      throw StateError(
        'databaseRuntimeFactoryProvider must be overridden with a '
        'platform-specific encrypted runtime.',
      );
    });

final Provider<Clock> clockProvider = Provider<Clock>((Ref ref) {
  return const SystemClock.utc();
});

final Provider<LocalLogBuffer> localLogBufferProvider =
    Provider<LocalLogBuffer>((Ref ref) => LocalLogBuffer());

final Provider<StructuredLogger> structuredLoggerProvider =
    Provider<StructuredLogger>((Ref ref) {
      final Clock clock = ref.watch(clockProvider);
      final AppConfig config = ref.watch(appConfigProvider);
      return StructuredLogger(
        utcNow: clock.utcNow,
        sinks: <LocalLogSink>[ref.watch(localLogBufferProvider)],
        minimumLevel: config.environment == ForgeEnvironment.production
            ? LogLevel.info
            : LogLevel.debug,
      );
    });

final Provider<LocalDiagnostics> localDiagnosticsProvider =
    Provider<LocalDiagnostics>((Ref ref) {
      final Clock clock = ref.watch(clockProvider);
      return LocalDiagnostics(
        utcNow: clock.utcNow,
        logBuffer: ref.watch(localLogBufferProvider),
      );
    });

/// The sole application-level Riverpod scope. Generation-scoped resources can
/// later be replaced atomically by rebuilding this boundary with overrides.
final class ForgeCompositionRoot extends StatelessWidget {
  const ForgeCompositionRoot({
    required this.config,
    required this.child,
    this.clock = const SystemClock.utc(),
    super.key,
  });

  final AppConfig config;
  final Widget child;
  final Clock clock;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        clockProvider.overrideWithValue(clock),
      ],
      child: child,
    );
  }
}
