import 'package:flutter/material.dart';

/// Warm off-white with ink-black actions (library redesign, 2026-10-19).
abstract final class AppColors {
  static const page = Color(0xFFF7F5F2);
  static const sidebar = Color(0xFFF2EFEB);
  static const card = Color(0xFFFFFFFF);

  /// Buttons, the chosen tab and chip: near-black.
  static const accent = Color(0xFF1E1D1C);

  /// Unchosen pills, tags, image placeholders.
  static const accentSoft = Color(0xFFEFEBE6);
  static const line = Color(0xFFE8E3DD);
  static const text = Color(0xFF1E1D1C);
  static const textMuted = Color(0xFF8A847E);

  /// The banner's badge and hand-written line.
  static const warm = Color(0xFFB0835A);
  static const warmSoft = Color(0xFFF6EBDD);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    primary: AppColors.accent,
    surface: AppColors.page,
  );
  const stadium = StadiumBorder();
  final text = ThemeData.light().textTheme.apply(bodyColor: AppColors.text, displayColor: AppColors.text);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.page,
    textTheme: text,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: AppColors.accentSoft,
        disabledForegroundColor: AppColors.textMuted,
        shape: stadium,
        // From labelLarge, so it keeps the body text's font family.
        textStyle: text.labelLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        side: const BorderSide(color: AppColors.line),
        shape: stadium,
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: AppColors.text)),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.accent),
  );
}

/// The library window is wide; a pushed page (sign-in, the custom flow) keeps
/// the narrow column it was laid out for, centred on the page colour.
MaterialPageRoute<T> narrowRoute<T>({required WidgetBuilder builder}) => MaterialPageRoute<T>(
      builder: (context) => ColoredBox(
        color: AppColors.page,
        child: Center(
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: builder(context)),
        ),
      ),
    );
