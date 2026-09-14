import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/app.dart';
import 'package:meridian/console/console_app.dart';
import 'package:meridian/theme.dart';
import 'package:meridian/theme_mode_store.dart';
import 'package:meridian/token_store.dart';

import 'fake_meridian_server.dart';

// The shared MD3 theme (ADR-0007): one construction site for all four
// frontends, light and dark both derived from the brand seed. Dark mode
// followed the system only until ADR-0010 revised that part: the
// Windows/Android 客户端's 我的 page now offers the theme three-state
// switch, stored client-locally, still defaulting to following the system;
// the Web 简易客户端 and the Console keep following the system. These
// tests pin the seams the tickets care about — scheme derivation,
// system-following, both MaterialApp construction sites actually consuming
// the shared themes, and the stored preference's round trip.

/// Reports the ambient theme brightness once per build, exactly the way the
/// apps' screens read it.
class _ThemeProbe extends StatelessWidget {
  final void Function(Brightness brightness) onBuild;

  const _ThemeProbe({required this.onBuild});

  @override
  Widget build(BuildContext context) {
    onBuild(Theme.of(context).brightness);
    return const SizedBox();
  }
}

MaterialApp _systemFollowingApp(Widget home) => MaterialApp(
      theme: meridianLightTheme,
      darkTheme: meridianDarkTheme,
      themeMode: ThemeMode.system,
      home: home,
    );

void main() {
  test('浅色与深色配色均由品牌种子色生成，仅亮度不同', () {
    expect(meridianLightTheme.colorScheme.brightness, Brightness.light);
    expect(meridianDarkTheme.colorScheme.brightness, Brightness.dark);

    expect(
      meridianLightTheme.colorScheme,
      ColorScheme.fromSeed(seedColor: kSeedColor),
    );
    expect(
      meridianDarkTheme.colorScheme,
      ColorScheme.fromSeed(
          seedColor: kSeedColor, brightness: Brightness.dark),
    );
  });

  testWidgets('系统深色偏好下取深色主题', (tester) async {
    Brightness? ambient;
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester
        .pumpWidget(_systemFollowingApp(_ThemeProbe(onBuild: (b) {
      ambient = b;
    })));
    expect(ambient, Brightness.dark);
  });

  testWidgets('系统浅色偏好下取浅色主题', (tester) async {
    Brightness? ambient;
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester
        .pumpWidget(_systemFollowingApp(_ThemeProbe(onBuild: (b) {
      ambient = b;
    })));
    expect(ambient, Brightness.light);
  });

  testWidgets('客户端 MaterialApp 消费共享主题并跟随系统', (tester) async {
    final fake = FakeMeridianServer();
    await tester.pumpWidget(
      MeridianApp(
        baseUrl: fake.url,
        tokenStore: InMemoryTokenStore(),
        apiClient: fake.client,
      ),
    );
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme, same(meridianLightTheme));
    expect(app.darkTheme, same(meridianDarkTheme));
    expect(app.themeMode, ThemeMode.system);
  });

  testWidgets('控制台 MaterialApp 消费共享主题并跟随系统', (tester) async {
    await tester.pumpWidget(const ConsoleApp());
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme, same(meridianLightTheme));
    expect(app.darkTheme, same(meridianDarkTheme));
    expect(app.themeMode, ThemeMode.system);
  });

  test('主题偏好名解析：空或未知一律回退跟随系统', () {
    expect(themeModeFromName(null), ThemeMode.system);
    expect(themeModeFromName('system'), ThemeMode.system);
    expect(themeModeFromName('light'), ThemeMode.light);
    expect(themeModeFromName('dark'), ThemeMode.dark);
    expect(themeModeFromName('nonsense'), ThemeMode.system);
  });

  testWidgets('客户端尊重本地存储的主题偏好，重启后保持', (tester) async {
    final fake = FakeMeridianServer();
    final modes = InMemoryThemeModeStore();
    await modes.write(ThemeMode.dark);

    // A fresh app on the same store stands in for the restart: nothing is
    // signed in, yet the stored preference already governs the MaterialApp.
    await tester.pumpWidget(
      MeridianApp(
        baseUrl: fake.url,
        tokenStore: InMemoryTokenStore(),
        themeModeStore: modes,
        apiClient: fake.client,
      ),
    );
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
  });
}
