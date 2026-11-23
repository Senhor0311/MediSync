import 'package:flutter/material.dart';

enum AppAccent { blue, purple, red, amber, green }

abstract final class AppTheme {
  static Color actionColor(AppAccent accent, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch (accent) {
      AppAccent.blue => dark ? const Color(0xFF93C5FD) : _blue,
      AppAccent.purple =>
        dark ? const Color(0xFFC4B5FD) : const Color(0xFF7C3AED),
      AppAccent.red => dark ? const Color(0xFFFCA5A5) : const Color(0xFFDC2626),
      AppAccent.amber =>
        dark ? const Color(0xFFFDE68A) : const Color(0xFF946200),
      AppAccent.green =>
        dark ? const Color(0xFF6EE7B7) : const Color(0xFF047857),
    };
  }

  // V2 brand colours are adapted here; widgets consume semantic roles only.
  static const _blue = Color(0xFF2563EB);
  static const _darkBlue = Color(0xFF1E3A8A);
  static final light = _build(Brightness.light);
  static final dark = _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colors =
        ColorScheme.fromSeed(seedColor: _blue, brightness: brightness).copyWith(
          primary: isDark ? const Color(0xFF93C5FD) : _blue,
          onPrimary: isDark ? const Color(0xFF172554) : Colors.white,
          primaryContainer: isDark ? _darkBlue : const Color(0xFFDBEAFE),
          onPrimaryContainer: isDark ? const Color(0xFFDBEAFE) : _darkBlue,
          secondary: isDark ? const Color(0xFFBFDBFE) : _darkBlue,
          onSecondary: isDark ? const Color(0xFF172554) : Colors.white,
          secondaryContainer: isDark ? _darkBlue : const Color(0xFFDBEAFE),
          onSecondaryContainer: isDark ? const Color(0xFFDBEAFE) : _darkBlue,
          surface: isDark ? const Color(0xFF0F172A) : const Color(0xFFF5F8FF),
          onSurface: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF172033),
          onSurfaceVariant: isDark
              ? const Color(0xFFB8C5D9)
              : const Color(0xFF475569),
          surfaceContainerLowest: isDark
              ? const Color(0xFF0B1220)
              : Colors.white,
          surfaceContainerLow: isDark ? const Color(0xFF162238) : Colors.white,
          surfaceContainer: isDark
              ? const Color(0xFF1C2A43)
              : const Color(0xFFEFF5FF),
          surfaceContainerHigh: isDark
              ? const Color(0xFF25344D)
              : const Color(0xFFE3EDFC),
          surfaceContainerHighest: isDark
              ? const Color(0xFF30415D)
              : const Color(0xFFDCE7F7),
          outline: isDark ? const Color(0xFF8496B1) : const Color(0xFF64748B),
          outlineVariant: isDark
              ? const Color(0xFF34445F)
              : const Color(0xFFD4DFEF),
        );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      visualDensity: VisualDensity.standard,
    );
    return base.copyWith(
      scaffoldBackgroundColor: colors.surface,
      textTheme: base.textTheme.copyWith(
        headlineLarge: base.textTheme.headlineLarge?.copyWith(
          fontSize: 30,
          fontWeight: FontWeight.w700,
          color: colors.secondary,
          height: 1.2,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: colors.secondary,
          height: 1.3,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.5),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.5),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? colors.primaryContainer : colors.primary,
        foregroundColor: isDark ? colors.onPrimaryContainer : colors.onPrimary,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: isDark ? colors.onPrimaryContainer : colors.onPrimary,
        ),
        toolbarHeight: 64,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: colors.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.outlineVariant),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant,
        thickness: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colors.surfaceContainerLow,
        indicatorColor: colors.secondaryContainer,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: colors.surfaceContainerLow,
        indicatorColor: colors.secondaryContainer,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }
}
