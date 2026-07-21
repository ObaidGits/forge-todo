import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/config/app_config.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/core/ui/forge_error.dart';
import 'package:forge/forge_app.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('failure view localizes safe copy and never renders its cause', (
    WidgetTester tester,
  ) async {
    const Failure failure = Failure(
      kind: FailureKind.storage,
      code: 'storage.write.failed',
      safeMessageKey: 'errorStorage',
      retryable: true,
      redactedCause: '/private/path/user-note.txt',
    );
    const AppConfig config = AppConfig(
      environment: ForgeEnvironment.test,
      releaseChannel: ReleaseChannel.nightly,
      buildRevision: 'test',
    );

    final GoRouter router = createFailureRouter(failure);
    addTearDown(router.dispose);
    await tester.pumpWidget(ForgeApp(config: config, router: router));
    await tester.pumpAndSettle();

    expect(find.textContaining('could not save locally'), findsOneWidget);
    expect(find.textContaining('/private/path'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('inline error exposes a localized retry action', (
    WidgetTester tester,
  ) async {
    int retries = 0;
    final GoRouter router = GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (BuildContext context, GoRouterState state) => Scaffold(
            body: ForgeInlineError(
              message: 'The command failed safely.',
              onRetry: () => retries += 1,
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(ForgeApp(config: testConfig, router: router));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Try again'));

    expect(retries, 1);
    expect(find.text('The command failed safely.'), findsOneWidget);
  });

  testWidgets('every failure kind maps to distinct safe localized copy', (
    WidgetTester tester,
  ) async {
    final GoRouter router = GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (BuildContext context, GoRouterState state) => Scaffold(
            body: Builder(
              builder: (BuildContext context) => Column(
                children: <Widget>[
                  for (final FailureKind kind in FailureKind.values)
                    Text(
                      localizedFailureMessage(
                        context,
                        Failure(
                          kind: kind,
                          code: 'test.${kind.name}',
                          safeMessageKey: 'test',
                          retryable: false,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(ForgeApp(config: testConfig, router: router));
    await tester.pumpAndSettle();

    for (final String message in <String>[
      'Check the highlighted information and try again.',
      'Forge does not have permission for that action.',
      'Forge could not save locally. Your changes were not discarded.',
      'The network is unavailable. Local work is still available.',
      'This item has conflicting changes that need review.',
      'This feature is not available on this device.',
      'Forge is completing maintenance. Try again shortly.',
      'Forge could not complete that action. Try again.',
    ]) {
      expect(find.text(message), findsOneWidget);
    }
  });
}

const AppConfig testConfig = AppConfig(
  environment: ForgeEnvironment.test,
  releaseChannel: ReleaseChannel.nightly,
  buildRevision: 'test',
);

// A MaterialApp supplies the same localization/theme boundary as ForgeApp.
// The view remains reusable by feature routes and inline command surfaces.
GoRouter createFailureRouter(Failure failure) => GoRouter(
  routes: <RouteBase>[
    GoRoute(
      path: '/',
      builder: (BuildContext context, GoRouterState state) => Scaffold(
        body: ForgeErrorView.forFailure(
          context: context,
          failure: failure,
          onRetry: () {},
        ),
      ),
    ),
  ],
);
