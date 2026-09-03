import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/app.dart';
import 'package:meridian/token_store.dart';

import 'fake_meridian_server.dart';

void main() {
  testWidgets('登录 → 创建备忘录 → 列表显示', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');

    await tester.pumpWidget(
      MeridianApp(
        baseUrl: fake.url,
        tokenStore: InMemoryTokenStore(),
        apiClient: fake.client,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login_button')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('username_field')), 'yifeng');
    await tester.enterText(find.byKey(const Key('password_field')), 'correct horse');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();

    // Landed on the memo list, still empty.
    expect(find.text('暂无备忘录'), findsOneWidget);

    await tester.tap(find.byKey(const Key('new_memo_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('title_field')), '购物清单');
    await tester.enterText(find.byKey(const Key('body_field')), '牛奶、鸡蛋');
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    // Back on the list, the new memo is there.
    expect(find.text('购物清单'), findsOneWidget);
    expect(find.text('牛奶、鸡蛋'), findsOneWidget);
  });

  testWidgets('错误密码被拒绝', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');

    await tester.pumpWidget(
      MeridianApp(
        baseUrl: fake.url,
        tokenStore: InMemoryTokenStore(),
        apiClient: fake.client,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('username_field')), 'yifeng');
    await tester.enterText(find.byKey(const Key('password_field')), 'wrong');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();

    expect(find.text('用户名或密码错误'), findsOneWidget);
    // Still on the login screen, not the memo list.
    expect(find.byKey(const Key('login_button')), findsOneWidget);
  });

  testWidgets('未初始化实例先创建管理员（Setup Wizard）', (tester) async {
    final fake = FakeMeridianServer(); // uninitialized

    await tester.pumpWidget(
      MeridianApp(
        baseUrl: fake.url,
        tokenStore: InMemoryTokenStore(),
        apiClient: fake.client,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('create_admin_button')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('username_field')), 'boss');
    await tester.enterText(find.byKey(const Key('password_field')), 'first password');
    await tester.tap(find.byKey(const Key('create_admin_button')));
    await tester.pumpAndSettle();

    // Straight into the app as the newly minted administrator.
    expect(find.text('暂无备忘录'), findsOneWidget);
  });

  testWidgets('凭据与备忘录在重开应用后仍在', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');

    final tokens = InMemoryTokenStore();
    Future<void> openApp() async {
      await tester.pumpWidget(
        MeridianApp(
          baseUrl: fake.url, tokenStore: tokens, apiClient: fake.client),
      );
      await tester.pumpAndSettle();
    }

    await openApp();
    await tester.enterText(find.byKey(const Key('username_field')), 'yifeng');
    await tester.enterText(find.byKey(const Key('password_field')), 'correct horse');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('new_memo_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('title_field')), '重启不丢');
    await tester.enterText(find.byKey(const Key('body_field')), '还在');
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();
    expect(find.text('重启不丢'), findsOneWidget);

    // Simulate an app restart: new widget tree, same token store.
    await tester.pumpWidget(const SizedBox());
    await openApp();
    expect(find.byKey(const Key('login_button')), findsNothing,
        reason: 'stored credential should skip login');
    expect(find.text('重启不丢'), findsOneWidget);
  });
}
