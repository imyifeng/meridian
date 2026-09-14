import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/api_client.dart';
import 'package:meridian/console/console_app.dart';

import 'fake_meridian_server.dart';

void main() {
  Future<void> signInAs(WidgetTester tester, FakeMeridianServer fake,
      {String username = 'admin', String password = 'correct horse'}) async {
    await tester.pumpWidget(
      ConsoleApp(api: MeridianApi(baseUrl: fake.url, client: fake.client)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('username_field')), username);
    await tester.enterText(find.byKey(const Key('password_field')), password);
    await tester.tap(find.byKey(const Key('console_login_button')));
    await tester.pumpAndSettle();
  }

  Future<void> switchToUsers(WidgetTester tester) async {
    await tester.tap(find.text('用户管理'));
    await tester.pumpAndSettle();
  }

  /// TabBarView 页面切换带动画，AI 设置页还要等加载 future 落定；
  /// future 完成后没有仍在跑的动画，pumpAndSettle 会停下来。
  Future<void> switchToAISettings(WidgetTester tester) async {
    await tester.tap(find.text('AI 设置'));
    await tester.pumpAndSettle();
  }

  testWidgets('Console 登录页不提供服务器地址输入', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('admin', 'correct horse');

    await tester.pumpWidget(
      ConsoleApp(api: MeridianApi(baseUrl: fake.url, client: fake.client)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('username_field')), findsOneWidget);
    expect(find.byKey(const Key('password_field')), findsOneWidget);
    expect(find.byKey(const Key('console_login_button')), findsOneWidget);
    // The console is served by the instance itself: there is no address to
    // type, so the shared form must not offer one.
    expect(find.byKey(const Key('server_address_field')), findsNothing);
  });

  testWidgets('Console 密码错误的提示与客户端一致', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('admin', 'correct horse');

    await tester.pumpWidget(
      ConsoleApp(api: MeridianApi(baseUrl: fake.url, client: fake.client)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('username_field')), 'admin');
    await tester.enterText(find.byKey(const Key('password_field')), 'wrong');
    await tester.tap(find.byKey(const Key('console_login_button')));
    await tester.pumpAndSettle();

    expect(find.text('用户名或密码错误'), findsOneWidget);
    expect(find.byKey(const Key('console_login_button')), findsOneWidget);
  });

  testWidgets('Console 断连的提示与客户端一致', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('admin', 'correct horse');
    fake.offline = true; // the instance is unreachable when signing in

    await tester.pumpWidget(
      ConsoleApp(api: MeridianApi(baseUrl: fake.url, client: fake.client)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('username_field')), 'admin');
    await tester.enterText(
        find.byKey(const Key('password_field')), 'correct horse');
    await tester.tap(find.byKey(const Key('console_login_button')));
    await tester.pumpAndSettle();

    expect(find.text('无法连接服务器，请检查服务器地址'), findsOneWidget);
    expect(find.byKey(const Key('console_login_button')), findsOneWidget);
  });

  testWidgets('管理员登录控制台，新增并删除分类', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('admin', 'correct horse');

    await signInAs(tester, fake);

    // The taxonomy shows the built-in 未分类, which offers no delete
    // affordance.
    expect(find.text('分类管理'), findsOneWidget);
    expect(find.byKey(const Key('category_未分类')), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);

    // Add 工作, then delete it again.
    await tester.enterText(find.byKey(const Key('category_name_field')), '工作');
    await tester.tap(find.byKey(const Key('add_category_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('category_工作')), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete_category_2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('category_工作')), findsNothing);
    // 未分类 survives — it is permanent (ADR-0002).
    expect(find.byKey(const Key('category_未分类')), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  testWidgets('已存在的分类名不会重复添加', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('admin', 'correct horse');

    await signInAs(tester, fake);
    await tester.enterText(find.byKey(const Key('category_name_field')), '工作');
    await tester.tap(find.byKey(const Key('add_category_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('category_name_field')), '工作');
    await tester.tap(find.byKey(const Key('add_category_button')));
    await tester.pumpAndSettle();

    expect(find.text('已存在同名分类'), findsOneWidget);
    expect(find.byKey(const Key('category_工作')), findsOneWidget);
  });

  testWidgets('非管理员登录只能查看分类', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('bob', 'bob password', role: 'user');

    await signInAs(tester, fake, username: 'bob', password: 'bob password');

    // Reading the taxonomy is for everyone…
    expect(find.byKey(const Key('category_未分类')), findsOneWidget);
    // …but there are no management controls for a non-administrator.
    expect(find.text('仅管理员可管理分类'), findsOneWidget);
    expect(find.byKey(const Key('category_name_field')), findsNothing);
    expect(find.byKey(const Key('add_category_button')), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    // User management is not even offered.
    expect(find.text('用户管理'), findsNothing);
  });

  testWidgets('管理员创建用户，新用户立即出现在列表并可登录', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('admin', 'correct horse');

    await signInAs(tester, fake);
    await switchToUsers(tester);
    await tester.enterText(find.byKey(const Key('new_username_field')), 'bob');
    await tester.enterText(find.byKey(const Key('new_password_field')), 'bob password');
    await tester.tap(find.byKey(const Key('create_user_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('user_bob')), findsOneWidget);

    // The issued credentials really work: the new user signs in at once,
    // and is an ordinary user.
    final api = MeridianApi(baseUrl: fake.url, client: fake.client);
    final session = await api.login('bob', 'bob password');
    expect(session.user.isAdministrator, isFalse);
  });

  testWidgets('已存在的用户名不会重复创建', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('admin', 'correct horse');
    fake.createUser('bob', 'bob password');

    await signInAs(tester, fake);
    await switchToUsers(tester);
    await tester.enterText(find.byKey(const Key('new_username_field')), 'bob');
    await tester.enterText(find.byKey(const Key('new_password_field')), 'another');
    await tester.tap(find.byKey(const Key('create_user_button')));
    await tester.pumpAndSettle();

    expect(find.text('用户名已存在'), findsOneWidget);
    expect(find.byKey(const Key('user_bob')), findsOneWidget);
  });

  testWidgets('管理员重置用户密码，旧密码随之失效', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('admin', 'correct horse');
    final bob = fake.createUser('bob', 'old password');

    await signInAs(tester, fake);
    await switchToUsers(tester);
    await tester.tap(find.byKey(Key('reset_password_${bob['id']}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('reset_password_field')), 'brand new');
    await tester.tap(find.byKey(const Key('confirm_reset_button')));
    await tester.pumpAndSettle();

    final api = MeridianApi(baseUrl: fake.url, client: fake.client);
    await expectLater(
      api.login('bob', 'old password'),
      throwsA(isA<ApiException>()),
    );
    final session = await api.login('bob', 'brand new');
    expect(session.token, isNotEmpty);
  });

  testWidgets('删除用户前确认框显示备忘录数量，确认后账号与数据一并消失', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('admin', 'correct horse');
    final bob = fake.createUser('bob', 'bob password');
    fake.seedMemo('bob', 'bob 的备忘录');

    await signInAs(tester, fake);
    await switchToUsers(tester);
    await tester.tap(find.byKey(Key('delete_user_${bob['id']}')));
    await tester.pumpAndSettle();

    // The confirmation names the number of memos the cascade will take.
    expect(find.textContaining('该用户有 1 条备忘录'), findsOneWidget);

    // Cancelling keeps the user.
    await tester.tap(find.byKey(const Key('cancel_delete_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('user_bob')), findsOneWidget);

    await tester.tap(find.byKey(Key('delete_user_${bob['id']}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm_delete_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('user_bob')), findsNothing);
    // The user is gone: their credentials no longer log in.
    final api = MeridianApi(baseUrl: fake.url, client: fake.client);
    await expectLater(
      api.login('bob', 'bob password'),
      throwsA(isA<ApiException>()),
    );
  });

  testWidgets('管理员删除其他管理员，确认框显示备忘录数量', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('admin', 'correct horse');
    fake.registerUser('chief', 'chief password', role: 'administrator');
    fake.seedMemo('chief', 'chief 的备忘录');

    await signInAs(tester, fake);
    await switchToUsers(tester);
    await tester.tap(find.byKey(Key('delete_user_${fake.userByName('chief')['id']}')));
    await tester.pumpAndSettle();

    // The confirmation names the number of memos the cascade will take —
    // an administrator's memos cascade like anyone else's (Story 26).
    expect(find.textContaining('该用户有 1 条备忘录'), findsOneWidget);

    await tester.tap(find.byKey(const Key('confirm_delete_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('user_chief')), findsNothing);
    // The deleted administrator is gone: their credentials no longer log in.
    final api = MeridianApi(baseUrl: fake.url, client: fake.client);
    await expectLater(
      api.login('chief', 'chief password'),
      throwsA(isA<ApiException>()),
    );
  });

  testWidgets('自己所在行没有删除入口', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('admin', 'correct horse');
    fake.createUser('bob', 'bob password');

    await signInAs(tester, fake);
    await switchToUsers(tester);

    // The signed-in administrator cannot delete themselves — the server
    // rejects it too (self_delete) — while other rows keep the affordance.
    expect(
      find.byKey(Key('delete_user_${fake.userByName('admin')['id']}')),
      findsNothing,
    );
    expect(
      find.byKey(Key('delete_user_${fake.userByName('bob')['id']}')),
      findsOneWidget,
    );
  });

  group('AI 设置', () {
    testWidgets('管理员打开 AI 设置，已存配置回显，保存生效', (tester) async {
      final fake = FakeMeridianServer();
      fake.registerUser('admin', 'correct horse');
      fake.aiSettings = {
        'base_url': 'https://llm.example.com/v1',
        'model': 'meridian-mini',
        'api_key': 'sk-existing-abcd1234',
        'enabled': true,
      };

      await signInAs(tester, fake);
      await switchToAISettings(tester);

      // 已存的非密字段回显；key 只以掩码出现。
      String text(String fieldKey) => tester
          .widget<TextField>(find.byKey(Key(fieldKey)))
          .controller!
          .text;
      expect(text('ai_base_url_field'), 'https://llm.example.com/v1');
      expect(text('ai_model_field'), 'meridian-mini');
      expect(text('ai_api_key_field'), isEmpty);
      expect(find.textContaining('sk-…1234'), findsOneWidget);

      // 修改模型名与开关，key 留空——留空即保留既存。
      await tester.enterText(
          find.byKey(const Key('ai_model_field')), 'meridian-max');
      await tester.tap(find.byKey(const Key('ai_enabled_switch')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('ai_save_button')));
      await tester.pumpAndSettle();

      expect(fake.aiSettings['model'], 'meridian-max');
      expect(fake.aiSettings['enabled'], isFalse);
      // 明文 key 原样保留，没有被打成空。
      expect(fake.aiSettings['api_key'], 'sk-existing-abcd1234');
      expect(find.text('已保存'), findsOneWidget);
    });

    testWidgets('管理员填入新 API Key，保存后覆盖既存', (tester) async {
      final fake = FakeMeridianServer();
      fake.registerUser('admin', 'correct horse');
      fake.aiSettings['api_key'] = 'sk-old-key-1111';

      await signInAs(tester, fake);
      await switchToAISettings(tester);
      await tester.enterText(
          find.byKey(const Key('ai_api_key_field')), 'sk-new-key-2222');
      await tester.tap(find.byKey(const Key('ai_save_button')));
      await tester.pumpAndSettle();

      expect(fake.aiSettings['api_key'], 'sk-new-key-2222');
    });

    testWidgets('测试连接：成功与失败都有结果反馈', (tester) async {
      final fake = FakeMeridianServer();
      fake.registerUser('admin', 'correct horse');

      await signInAs(tester, fake);
      await switchToAISettings(tester);

      fake.aiTestResult = {'success': true};
      await tester.tap(find.byKey(const Key('ai_test_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ai_test_result')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('ai_test_result'))).data,
        '连接成功',
      );
      expect(fake.aiTestCalls, 1);

      fake.aiTestResult = {
        'success': false,
        'reason': '无法连接模型服务：connection refused',
      };
      await tester.tap(find.byKey(const Key('ai_test_button')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('ai_test_result'))).data,
        '无法连接模型服务：connection refused',
      );
    });

    testWidgets('非管理员没有 AI 设置入口', (tester) async {
      final fake = FakeMeridianServer();
      fake.registerUser('bob', 'bob password', role: 'user');

      await signInAs(tester, fake, username: 'bob', password: 'bob password');

      expect(find.text('AI 设置'), findsNothing);
      // 用户管理也不在：非管理员的控制台只有分类体系。
      expect(find.text('用户管理'), findsNothing);
    });
  });
}
