import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/app.dart';
import 'package:meridian/token_store.dart';

import 'fake_meridian_server.dart';
import 'login_harness.dart';

// The client's navigation shell (#71): four pages — 首页, 智能体, 搜索,
// 我的 — behind a bottom NavigationBar that widens into a NavigationRail
// at the MD3 expanded breakpoint. The nav destination finders are scoped
// to the shell, because every mounted tab stays in the tree (IndexedStack)
// and page titles repeat the labels.

Finder _navLabel(String label) => find.descendant(
    of: find.byKey(const Key('nav_bar')), matching: find.text(label));

MeridianApp clientApp(FakeMeridianServer fake) => MeridianApp(
      baseUrl: fake.url,
      tokenStore: InMemoryTokenStore(),
      apiClient: fake.client,
    );

void main() {
  testWidgets('登录后出现底栏四项，默认停在首页', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');

    await pumpAndLogin(tester, clientApp(fake), 'yifeng', 'correct horse');

    expect(find.byKey(const Key('nav_bar')), findsOneWidget);
    expect(find.byKey(const Key('nav_rail')), findsNothing,
        reason: '窄窗口（默认 800px 宽）用底栏，不用侧栏');
    expect(_navLabel('首页'), findsOneWidget);
    expect(_navLabel('智能体'), findsOneWidget);
    expect(_navLabel('搜索'), findsOneWidget);
    expect(_navLabel('我的'), findsOneWidget);

    final bar =
        tester.widget<NavigationBar>(find.byKey(const Key('nav_bar')));
    expect(bar.selectedIndex, 0, reason: '登录后默认停在首页');
  });

  testWidgets('底栏可在四页间往返，首页回来后列表原样保留', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '购物清单', body: '牛奶、鸡蛋');

    await pumpAndLogin(tester, clientApp(fake), 'yifeng', 'correct horse');

    await tester.tap(_navLabel('我的'));
    await tester.pumpAndSettle();
    // Off the home tab, the memo list is no longer the page on show (its
    // rows stay in the tree but out of the painted IndexedStack index).
    expect(find.text('购物清单').hitTestable(), findsNothing);

    await tester.tap(_navLabel('首页'));
    await tester.pumpAndSettle();
    // The home tab kept its state across the round trip: the seeded memo is
    // still there.
    expect(find.text('购物清单'), findsOneWidget);
  });

  testWidgets('智能体页显示未配置的空态占位', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');

    await pumpAndLogin(tester, clientApp(fake), 'yifeng', 'correct horse');

    await tester.tap(_navLabel('智能体'));
    await tester.pumpAndSettle();

    expect(find.text('智能体尚未配置'), findsOneWidget);
    expect(find.text('请联系管理员在 Web 管理控制台完成 AI 设置'), findsOneWidget);
  });

  testWidgets('搜索页显示建设中占位，首页内嵌搜索原位保留', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '购物清单');

    await pumpAndLogin(tester, clientApp(fake), 'yifeng', 'correct horse');

    await tester.tap(_navLabel('搜索'));
    await tester.pumpAndSettle();
    expect(find.text('搜索页建设中'), findsOneWidget);

    // The home app-bar search stays where it was this ticket (#72 moves it).
    await tester.tap(_navLabel('首页'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('search_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search_field')), findsOneWidget);
  });

  testWidgets('宽窗口下底栏换为左侧栏，仍可切换页面', (tester) async {
    // MD3 expanded: 1200 logical px wide, past the 840 breakpoint.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '购物清单');

    await pumpAndLogin(tester, clientApp(fake), 'yifeng', 'correct horse');

    expect(find.byKey(const Key('nav_rail')), findsOneWidget);
    expect(find.byKey(const Key('nav_bar')), findsNothing);

    // The rail switches pages the way the bar does.
    await tester.tap(find.descendant(
        of: find.byKey(const Key('nav_rail')),
        matching: find.text('我的')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sign_out_button')).hitTestable(),
        findsOneWidget);

    await tester.tap(find.descendant(
        of: find.byKey(const Key('nav_rail')),
        matching: find.text('首页')));
    await tester.pumpAndSettle();
    expect(find.text('购物清单').hitTestable(), findsOneWidget);
  });

  testWidgets('登出入口：Web 简易客户端保留应用栏登出，原生客户端首页不再有', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');

    // The Web 简易客户端 has no 我的 page, so its app-bar logout must stay
    // — and keep working.
    await pumpAndLogin(
        tester,
        MeridianApp(
          baseUrl: '',
          tokenStore: InMemoryTokenStore(),
          apiClient: fake.client,
          webClient: true,
        ),
        'yifeng',
        'correct horse');
    expect(find.byKey(const Key('logout_button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('logout_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login_button')), findsOneWidget);

    // The Windows/Android 客户端's home drops the app-bar logout (#71):
    // sign-out lives on the 我的 page alone.
    await tester.pumpWidget(const SizedBox());
    await pumpAndLogin(tester, clientApp(fake), 'yifeng', 'correct horse');
    expect(find.byKey(const Key('logout_button')), findsNothing);
  });
}
