import 'package:flutter/material.dart';

import 'tokens.dart';

/// App-wide theme. Body text uses DM Sans; headings use Cormorant Garamond.
/// Both fall back to Hind Siliguri so Bengali glyphs always render — DM Sans
/// and Cormorant Garamond have no Bengali coverage of their own.
class AppTheme {
  AppTheme._();

  static const String headingFontFamily = 'Cormorant Garamond';
  static const String bodyFontFamily = 'DM Sans';
  static const List<String> bengaliFallback = ['Hind Siliguri'];

  static ThemeData get theme {
    final baseTextTheme = Typography.material2021(
      platform: TargetPlatform.android,
    ).black.apply(
          fontFamily: bodyFontFamily,
          fontFamilyFallback: bengaliFallback,
          bodyColor: AppTokens.ink,
          displayColor: AppTokens.ink,
        );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppTokens.verdant,
      canvasColor: AppTokens.verdant,
      fontFamily: bodyFontFamily,
      textTheme: baseTextTheme,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppTokens.verdant,
        primary: AppTokens.verdant,
        error: AppTokens.error,
        surface: AppTokens.ivory,
      ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
