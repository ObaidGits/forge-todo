import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

enum GoldenViewport {
  compact(Size(390, 844)),
  medium(Size(840, 900)),
  expanded(Size(1440, 1024));

  const GoldenViewport(this.size);
  final Size size;
}

final class CanonicalGoldenVariant {
  const CanonicalGoldenVariant({
    required this.viewport,
    required this.brightness,
    this.textScale = 1,
    this.highContrast = false,
  });

  final GoldenViewport viewport;
  final Brightness brightness;
  final double textScale;
  final bool highContrast;

  String get suffix {
    final String contrast = highContrast ? 'high-contrast' : 'standard';
    return '${viewport.name}-${brightness.name}-${textScale}x-$contrast';
  }
}

const List<CanonicalGoldenVariant> canonicalGoldenVariants =
    <CanonicalGoldenVariant>[
      CanonicalGoldenVariant(
        viewport: GoldenViewport.compact,
        brightness: Brightness.light,
      ),
      CanonicalGoldenVariant(
        viewport: GoldenViewport.medium,
        brightness: Brightness.dark,
      ),
      CanonicalGoldenVariant(
        viewport: GoldenViewport.expanded,
        brightness: Brightness.light,
        textScale: 2,
        highContrast: true,
      ),
    ];

Future<void> pumpCanonicalGolden(
  WidgetTester tester,
  Widget child, {
  required CanonicalGoldenVariant variant,
}) async {
  final Size size = variant.viewport.size;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  const Locale canonicalLocale = Locale('en', 'US');
  tester.platformDispatcher.localesTestValue = const <Locale>[canonicalLocale];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);

  final MediaQueryData mediaQueryData = MediaQueryData(
    size: size,
    devicePixelRatio: 1,
    textScaler: TextScaler.linear(variant.textScale),
    highContrast: variant.highContrast,
    platformBrightness: variant.brightness,
  );
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: canonicalLocale,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: variant.brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      builder: (BuildContext context, Widget? appChild) => MediaQuery(
        data: mediaQueryData,
        child: appChild ?? const SizedBox.shrink(),
      ),
      home: child,
    ),
  );
  await tester.pump();
}

ThemeData _theme(Brightness brightness) => ThemeData(
  useMaterial3: true,
  brightness: brightness,
  fontFamily: 'Ahem',
  platform: TargetPlatform.linux,
);
