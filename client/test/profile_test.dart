import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/app.dart';
import 'package:meridian/identity_store.dart';
import 'package:meridian/theme_mode_store.dart';
import 'package:meridian/token_store.dart';

import 'fake_meridian_server.dart';
import 'login_harness.dart';

// The 我的 page (#71): the signed-in account's username and role, and the
// theme three-state switch (ADR-0010). Nav finders are scoped to the shell
// because every mounted tab stays in the tree (IndexedStack) and page
// titles repeat the labels.

Finder _navLabel(String label) => find.descendant(
    of: find.byKey(const Key('nav_bar')), matching: find.text(label));

MeridianApp clientApp(FakeMeridianServer fake,
        {TokenStore? tokens,
        IdentityStore? identities,
        ThemeModeStore? modes}) =>
    MeridianApp(
      baseUrl: fake.url,
      tokenStore: tokens ?? InMemoryTokenStore(),
      identityStore: identities,
      themeModeStore: modes,
      apiClient: fake.client,
    );

void main() {
  testWidgets('我的页显示当前账号的用户名与角色（管理员）', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse'); // the setup role

    await pumpAndLogin(tester, clientApp(fake), 'yifeng', 'correct horse');
    await tester.tap(_navLabel('我的'));
    await tester.pumpAndSettle();

    expect(find.text('yifeng'), findsOneWidget);
    expect(find.text('管理员'), findsOneWidget);
    expect(find.text('用户'), findsNothing);
  });

  testWidgets('我的页显示普通用户的角色', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('boss', 'correct horse');
    fake.createUser('amy', 'her password');

    await pumpAndLogin(tester, clientApp(fake), 'amy', 'her password');
    await tester.tap(_navLabel('我的'));
    await tester.pumpAndSettle();

    expect(find.text('amy'), findsOneWidget);
    expect(find.text('用户'), findsOneWidget);
    expect(find.text('管理员'), findsNothing);
  });

  testWidgets('重启应用后我的页仍显示用户名与角色', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('boss', 'correct horse');
    fake.createUser('amy', 'her password');

    final tokens = InMemoryTokenStore();
    final identities = InMemoryIdentityStore();

    Future<void> openApp() async {
      await tester.pumpWidget(
          clientApp(fake, tokens: tokens, identities: identities));
      await tester.pumpAndSettle();
    }

    await openApp();
    await tester.enterText(find.byKey(const Key('username_field')), 'amy');
    await tester.enterText(find.byKey(const Key('password_field')), 'her password');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();

    // Simulate an app restart: new widget tree, same stores. The stored
    // credential skips login, and the identity the login taught the client
    // must still feed the 我的 page.
    await tester.pumpWidget(const SizedBox());
    await openApp();
    expect(find.byKey(const Key('login_button')), findsNothing);

    await tester.tap(_navLabel('我的'));
    await tester.pumpAndSettle();
    expect(find.text('amy'), findsOneWidget);
    expect(find.text('用户'), findsOneWidget);
  });

  testWidgets('我的页可退出登录，回到登录页', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('boss', 'correct horse');
    fake.createUser('amy', 'her password');

    await pumpAndLogin(tester, clientApp(fake), 'amy', 'her password');
    await tester.tap(_navLabel('我的'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sign_out_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('login_button')), findsOneWidget);
    expect(find.byKey(const Key('sign_out_button')), findsNothing);
  });

  testWidgets('主题默认跟随系统，选深色立即生效并写入本地', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    final modes = InMemoryThemeModeStore();

    await tester.pumpWidget(clientApp(fake, modes: modes));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('username_field')), 'yifeng');
    await tester.enterText(
        find.byKey(const Key('password_field')), 'correct horse');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();

    await tester.tap(_navLabel('我的'));
    await tester.pumpAndSettle();

    // The ADR-0010 default: follow the system until the user says otherwise.
    expect(find.text('主题'), findsOneWidget);
    expect(find.byKey(const Key('theme_mode_dark')), findsOneWidget);
    expect(find.byKey(const Key('theme_mode_light')), findsOneWidget);
    expect(find.byKey(const Key('theme_mode_system')), findsOneWidget);
    MaterialApp app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);

    await tester.tap(find.byKey(const Key('theme_mode_dark')));
    await tester.pumpAndSettle();

    // Immediate effect, and the choice lands in the client-local store —
    // never in account data.
    app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    expect(await modes.read(), ThemeMode.dark);
  });
}
