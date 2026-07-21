import 'package:flutter/material.dart';
import 'package:forge/core/ui/forge_tokens.dart';

abstract final class ForgeTheme {
  static const Color seed = Color(0xFF4F5DFF);

  static ThemeData light({bool highContrast = false}) =>
      _theme(brightness: Brightness.light, highContrast: highContrast);

  static ThemeData dark({bool highContrast = false}) =>
      _theme(brightness: Brightness.dark, highContrast: highContrast);

  static ThemeData _theme({
    required Brightness brightness,
    required bool highContrast,
  }) {
    final ColorScheme colors = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      contrastLevel: highContrast ? 1 : 0,
    );
    final ThemeData base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colors,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
    );
    return base.copyWith(
      cardTheme: CardThemeData(
        elevation: 0,
        color: colors.surfaceContainerLow,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(ForgeRadii.card)),
        ),
      ),
      focusColor: colors.primary.withValues(alpha: 0.18),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(ForgeRadii.control)),
        ),
      ),
      extensions: <ThemeExtension<dynamic>>[_semanticColors(brightness)],
    );
  }

  static ForgeSemanticColors _semanticColors(Brightness brightness) {
    final bool dark = brightness == Brightness.dark;
    return ForgeSemanticColors(
      success: dark ? const Color(0xFF75DB8A) : const Color(0xFF176B35),
      onSuccess: dark ? const Color(0xFF003914) : Colors.white,
      successContainer: dark
          ? const Color(0xFF075226)
          : const Color(0xFFB9F3C5),
      onSuccessContainer: dark ? Colors.white : const Color(0xFF002109),
      warning: dark ? const Color(0xFFFFC66A) : const Color(0xFF7A4E00),
      onWarning: dark ? const Color(0xFF402900) : Colors.white,
      warningContainer: dark
          ? const Color(0xFF5C3B00)
          : const Color(0xFFFFDFA5),
      onWarningContainer: dark ? Colors.white : const Color(0xFF271900),
      info: dark ? const Color(0xFF9CCAFF) : const Color(0xFF075A9C),
      onInfo: dark ? const Color(0xFF003258) : Colors.white,
      infoContainer: dark ? const Color(0xFF00497D) : const Color(0xFFD1E4FF),
      onInfoContainer: dark ? Colors.white : const Color(0xFF001D35),
    );
  }
}
