// The MD3 design system for all four frontends (ADR-0007): one ThemeData
// construction site shared by the Windows/Android client and the Web
// 简易客户端 (app.dart) and by the Web 管理控制台 (console_app.dart).
//
// Light and dark palettes both derive from the brand seed via
// ColorScheme.fromSeed. Dark mode follows the system by default
// (ThemeMode.system — on the web that is the browser's
// prefers-color-scheme); since ADR-0010 the Windows/Android 客户端's 我的
// page also offers the three-state in-app switch (深色/浅色/跟随系统,
// stored
// client-locally via theme_mode_store.dart, never in account data), while
// the Web 简易客户端 and the Console keep following the system.
// dynamic_color is deliberately unused: it is Android-only and would break
// the four-frontends-one-look rule. Component themes below cover only the
// components the screens actually use; everything else keeps the
// framework's own MD3 defaults.

import 'package:flutter/material.dart';

/// The stored theme preference's three states, parsed from the name the
/// store persists ([ThemeMode.name]). Anything absent or unrecognized — a
/// fresh install, a garbled entry — falls back to following the system,
/// the ADR-0007/0010 default. Parsing lives here so the theme definition
/// keeps its single source.
ThemeMode themeModeFromName(String? name) => switch (name) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

/// Brand seed color: teal — what every frontend has always shipped with.
const Color kSeedColor = Colors.teal;

/// Font token: the platform default (null). Bundling a font face would add a
/// multi-MB asset without helping a zh-CN UI — each platform's default stack
/// already carries a CJK fallback — so the family stays overridable from
/// this one constant instead.
const String? kFontFamily = null;

/// Corner radius for text fields (the app's small-shape token, within the
/// MD3 shape scale).
const double kFieldRadius = 12;

/// Corner radius for the floating action buttons (the MD3 FAB shape).
const double kFabRadius = 16;

/// The light palette.
final ThemeData meridianLightTheme = buildMeridianTheme(Brightness.light);

/// The dark palette.
final ThemeData meridianDarkTheme = buildMeridianTheme(Brightness.dark);

/// Builds the theme for one brightness. Both MaterialApps hand this file's
/// [meridianLightTheme]/[meridianDarkTheme] to `theme`/`darkTheme` and leave
/// `themeMode` at [ThemeMode.system]; no screen may construct its own
/// ThemeData (ADR-0007 keeps ThemeData in exactly one place).
ThemeData buildMeridianTheme(Brightness brightness) {
  final scheme =
      ColorScheme.fromSeed(seedColor: kSeedColor, brightness: brightness);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: kFontFamily,
    // MD3 app bars are flat surface, not tinted-on-scroll surface.
    appBarTheme: AppBarThemeData(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    // Flutter's default decorator is still the M2 underline; MD3 fields are
    // filled. Border colors stay framework-resolved (outline when enabled,
    // primary when focused).
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kFieldRadius),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kFabRadius),
      ),
    ),
  );
}
