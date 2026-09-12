import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/app.dart';
import 'package:meridian/console/console_app.dart';
import 'package:meridian/theme.dart';
import 'package:meridian/token_store.dart';

import 'fake_meridian_server.dart';

// The shared MD3 theme (ADR-0007): one construction site for all four
// frontends, light and dark both derived from the brand seed, dark mode
// following the system only. These tests pin the seams the ticket cares
// about — scheme derivation, system-following, and both MaterialApp
// construction sites actually consuming the shared themes.

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
}
