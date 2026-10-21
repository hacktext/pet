import 'package:flutter/material.dart';

/// Cream and coffee with an apricot lead (palette of 2026-10-20's mockup).
abstract final class AppColors {
  static const page = Color(0xFFFFF8F0);
  static const sidebar = Color(0xFFF8F0E5);
  static const card = Color(0xFFFFFCF8);

  /// Buttons on cards and the custom flow, the chosen half of 宠物 | 人物.
  static const accent = Color(0xFF7D4B32);

  /// The lead action -- the chosen nav item and category, 立即定制 -- runs
  /// [orangeLight] to [orange].
  static const orange = Color(0xFFE8894F);
  static const orangeLight = Color(0xFFF3B07C);
  static const orangeGradient = LinearGradient(colors: [orangeLight, orange]);

  /// Unchosen pills, tags, image placeholders.
  static const accentSoft = Color(0xFFF8E8D9);
  static const line = Color(0xFFF0E0CF);
  static const text = Color(0xFF5A3423);
  static const textMuted = Color(0xFFA2826F);

  /// The banner's badge and hand-written line.
  static const warm = Color(0xFF8A5A3E);
  static const warmSoft = Color(0xFFFBEBDB);
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

/// The page's lead action (立即定制): white on the apricot gradient, in a
/// pill. The theme's FilledButton stays coffee for everything else.
class LeadButton extends StatelessWidget {
  const LeadButton({super.key, required this.onPressed, required this.child});

  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
        type: MaterialType.transparency,
        child: Ink(
          decoration: const ShapeDecoration(
            gradient: AppColors.orangeGradient,
            shape: StadiumBorder(),
            shadows: [BoxShadow(color: Color(0x40E8894F), blurRadius: 14, offset: Offset(0, 6))],
          ),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Center(
                widthFactor: 1,
                child: DefaultTextStyle.merge(
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                  child: IconTheme.merge(data: const IconThemeData(color: Colors.white), child: child),
                ),
              ),
            ),
          ),
        ),
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
