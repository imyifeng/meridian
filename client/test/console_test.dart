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

  testWidgets('非管理员能看到分类，但改动被服务器拒绝', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('bob', 'bob password', role: 'user');

    await signInAs(tester, fake, username: 'bob', password: 'bob password');

    // Reading the taxonomy is for everyone.
    expect(find.byKey(const Key('category_未分类')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('category_name_field')), 'bob 的分类');
    await tester.tap(find.byKey(const Key('add_category_button')));
    await tester.pumpAndSettle();

    expect(find.text('仅管理员可管理分类'), findsOneWidget);
    expect(find.byKey(const Key('category_bob 的分类')), findsNothing);
  });
}
