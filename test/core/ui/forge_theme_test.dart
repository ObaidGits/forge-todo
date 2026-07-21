import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/ui/forge_theme.dart';
import 'package:forge/core/ui/forge_tokens.dart';

void main() {
  test('themes use Material 3, padded targets, and semantic color roles', () {
    final ThemeData light = ForgeTheme.light();
    final ThemeData dark = ForgeTheme.dark();

    expect(light.useMaterial3, isTrue);
    expect(light.materialTapTargetSize, MaterialTapTargetSize.padded);
    expect(light.extension<ForgeSemanticColors>(), isNotNull);
    expect(dark.extension<ForgeSemanticColors>(), isNotNull);
  });

  test('semantic colors copy and interpolate every role', () {
    const ForgeSemanticColors original = ForgeSemanticColors(
      success: Color(0xff010101),
      onSuccess: Color(0xff020202),
      successContainer: Color(0xff030303),
      onSuccessContainer: Color(0xff040404),
      warning: Color(0xff050505),
      onWarning: Color(0xff060606),
      warningContainer: Color(0xff070707),
      onWarningContainer: Color(0xff080808),
      info: Color(0xff090909),
      onInfo: Color(0xff0a0a0a),
      infoContainer: Color(0xff0b0b0b),
      onInfoContainer: Color(0xff0c0c0c),
    );
    const ForgeSemanticColors target = ForgeSemanticColors(
      success: Color(0xff111111),
      onSuccess: Color(0xff121212),
      successContainer: Color(0xff131313),
      onSuccessContainer: Color(0xff141414),
      warning: Color(0xff151515),
      onWarning: Color(0xff161616),
      warningContainer: Color(0xff171717),
      onWarningContainer: Color(0xff181818),
      info: Color(0xff191919),
      onInfo: Color(0xff1a1a1a),
      infoContainer: Color(0xff1b1b1b),
      onInfoContainer: Color(0xff1c1c1c),
    );

    final ForgeSemanticColors copied = original.copyWith(
      success: target.success,
      onSuccess: target.onSuccess,
      successContainer: target.successContainer,
      onSuccessContainer: target.onSuccessContainer,
      warning: target.warning,
      onWarning: target.onWarning,
      warningContainer: target.warningContainer,
      onWarningContainer: target.onWarningContainer,
      info: target.info,
      onInfo: target.onInfo,
      infoContainer: target.infoContainer,
      onInfoContainer: target.onInfoContainer,
    );
    expect(_semanticRoles(copied), _semanticRoles(target));
    expect(original.lerp(null, 0.5), same(original));

    final ForgeSemanticColors midpoint = original.lerp(target, 0.5);
    expect(
      _semanticRoles(midpoint),
      List<Color>.generate(
        _semanticRoles(original).length,
        (int index) => Color.lerp(
          _semanticRoles(original)[index],
          _semanticRoles(target)[index],
          0.5,
        )!,
      ),
    );
  });

  test('high contrast themes increase generated scheme contrast', () {
    final ThemeData ordinary = ForgeTheme.light();
    final ThemeData highContrast = ForgeTheme.light(highContrast: true);

    expect(
      _contrastRatio(
        highContrast.colorScheme.onSurface,
        highContrast.colorScheme.surface,
      ),
      greaterThanOrEqualTo(
        _contrastRatio(
          ordinary.colorScheme.onSurface,
          ordinary.colorScheme.surface,
        ),
      ),
    );
  });
}

List<Color> _semanticRoles(ForgeSemanticColors colors) => <Color>[
  colors.success,
  colors.onSuccess,
  colors.successContainer,
  colors.onSuccessContainer,
  colors.warning,
  colors.onWarning,
  colors.warningContainer,
  colors.onWarningContainer,
  colors.info,
  colors.onInfo,
  colors.infoContainer,
  colors.onInfoContainer,
];

double _contrastRatio(Color foreground, Color background) {
  final double lighter =
      foreground.computeLuminance() > background.computeLuminance()
      ? foreground.computeLuminance()
      : background.computeLuminance();
  final double darker =
      foreground.computeLuminance() > background.computeLuminance()
      ? background.computeLuminance()
      : foreground.computeLuminance();
  return (lighter + 0.05) / (darker + 0.05);
}
