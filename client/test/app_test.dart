import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:super_editor/super_editor_test.dart';

import 'package:meridian/app.dart';
import 'package:meridian/token_store.dart';

import 'fake_meridian_server.dart';

// Focuses the WYSIWYG body and types into it like a keyboard would.
Future<void> typeBody(WidgetTester tester, String text) async {
  await tester.tap(find.byType(SuperEditor));
  await tester.pumpAndSettle();
  await tester.typeImeText(text);
  await tester.pumpAndSettle();
}

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
    await typeBody(tester, '牛奶、鸡蛋');
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

    expect(find.byKey(const Key('create_administrator_button')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('username_field')), 'boss');
    await tester.enterText(find.byKey(const Key('password_field')), 'first password');
    await tester.tap(find.byKey(const Key('create_administrator_button')));
    await tester.pumpAndSettle();

    // Straight into the app as the newly minted administrator.
    expect(find.text('暂无备忘录'), findsOneWidget);
  });

  testWidgets('实例被他人初始化后，向导把用户送往登录页', (tester) async {
    final fake = FakeMeridianServer(); // uninitialized when the app boots

    await tester.pumpWidget(
      MeridianApp(
        baseUrl: fake.url,
        tokenStore: InMemoryTokenStore(),
        apiClient: fake.client,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('create_administrator_button')), findsOneWidget);

    // Someone else completes the wizard before this user submits.
    fake.registerUser('someoneelse', 'their password');

    await tester.enterText(find.byKey(const Key('username_field')), 'boss');
    await tester.enterText(find.byKey(const Key('password_field')), 'first password');
    await tester.tap(find.byKey(const Key('create_administrator_button')));
    await tester.pumpAndSettle();

    expect(find.text('实例已初始化过，请直接登录'), findsNothing,
        reason: 'the wizard screen is replaced by login');
    expect(find.byKey(const Key('login_button')), findsOneWidget);
    expect(find.byKey(const Key('create_administrator_button')), findsNothing);
  });

  testWidgets('备忘录默认归入未分类，可改到既有分类', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.createCategory('工作');

    await tester.pumpWidget(
      MeridianApp(
        baseUrl: fake.url,
        tokenStore: InMemoryTokenStore(),
        apiClient: fake.client,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('username_field')), 'yifeng');
    await tester.enterText(find.byKey(const Key('password_field')), 'correct horse');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();

    // A new memo: the category picker only offers the fixed taxonomy, with
    // the built-in 未分类 preselected.
    await tester.tap(find.byKey(const Key('new_memo_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('category_dropdown')), findsOneWidget);
    expect(find.text('未分类'), findsOneWidget);
    expect(find.text('工作'), findsNothing, reason: '只能选既有分类，不能自创');

    await tester.enterText(find.byKey(const Key('title_field')), '购物清单');
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    // Back on the list, the memo is filed under 未分类.
    expect(find.text('购物清单'), findsOneWidget);
    expect(find.text('未分类'), findsOneWidget);

    // Move it to 工作 through the picker.
    await tester.tap(find.text('购物清单'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('category_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('工作').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    expect(find.text('购物清单'), findsOneWidget);
    expect(find.text('工作'), findsOneWidget, reason: '列表显示新分类');
    expect(find.text('未分类'), findsNothing);
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
    await typeBody(tester, '还在');
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
