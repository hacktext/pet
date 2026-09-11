import 'package:flutter/material.dart';

/// Our own warm palette (spec 5) -- deliberately not the competitor's pink.
abstract final class AppColors {
  static const page = Color(0xFFFFF8F0);
  static const card = Color(0xFFFFFFFF);
  static const accent = Color(0xFFF08A3C);
  static const accentSoft = Color(0xFFFDEBD9);
  static const text = Color(0xFF3D2B1F);
  static const textMuted = Color(0xFF8A6E5A);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.accent, surface: AppColors.page);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.page,
    textTheme: ThemeData.light().textTheme.apply(bodyColor: AppColors.text, displayColor: AppColors.text),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: AppColors.card,
      indicatorColor: AppColors.accentSoft,
    ),
  );
}
