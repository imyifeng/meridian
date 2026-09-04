import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/app.dart';
import 'package:meridian/token_store.dart';

import 'fake_meridian_server.dart';

void main() {
  // Boots the app on the fake instance and signs in as yifeng.
  Future<void> loginAsYifeng(WidgetTester tester, FakeMeridianServer fake) async {
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
  }

  // Opens the search field and commits a query the way a keyboard's return
  // key does. Still in search mode from a previous query, it backs out
  // first — the field lives in the app bar only while search mode is open.
  Future<void> search(WidgetTester tester, String query) async {
    final clear = find.byKey(const Key('clear_search_button'));
    if (clear.evaluate().isNotEmpty) {
      await tester.tap(clear);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const Key('search_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('search_field')), query);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets('搜索命中标题、正文与标签，清除后恢复完整列表', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.createUser('bob', 'bob password');
    fake.seedMemo('yifeng', '英语学习笔记', body: '今天背了五十个词', tags: ['日常']);
    fake.seedMemo('yifeng', '购物清单', body: 'abandon 练习册');
    // 正文没有"英语"两个字，标签命中也要搜得到 (T6)。
    fake.seedMemo('yifeng', '周末安排', body: '睡个懒觉', tags: ['英语']);
    // bob 的同词备忘录绝不混进来。
    fake.seedMemo('bob', '英语学习笔记', body: '今天背了五十个词', tags: ['英语']);
    await loginAsYifeng(tester, fake);

    await search(tester, '英语');
    expect(find.text('英语学习笔记'), findsOneWidget,
        reason: '只应命中 yifeng 自己的，bob 的不出现');
    expect(find.text('周末安排'), findsOneWidget, reason: '标签命中');
    expect(find.text('购物清单'), findsNothing);

    // 换个词，正文来源也能命中。
    await search(tester, 'abandon');
    expect(find.text('购物清单'), findsOneWidget);
    expect(find.text('英语学习笔记'), findsNothing);

    // 退出搜索，完整列表回来。
    await tester.tap(find.byKey(const Key('clear_search_button')));
    await tester.pumpAndSettle();
    expect(find.text('英语学习笔记'), findsOneWidget);
    expect(find.text('购物清单'), findsOneWidget);
    expect(find.text('周末安排'), findsOneWidget);
  });

  testWidgets('回收站里的备忘录不出现在搜索结果，恢复后重新可搜', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '会议纪要', body: '下周一交付', tags: ['英语']);
    await loginAsYifeng(tester, fake);

    // 删进回收站。
    await tester.tap(find.text('会议纪要'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    await search(tester, '交付');
    expect(find.text('会议纪要'), findsNothing);
    expect(find.text('未找到匹配的备忘录'), findsOneWidget);

    // 恢复后重新可搜。
    await tester.tap(find.byKey(const Key('clear_search_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trash_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore_button_1')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    await search(tester, '交付');
    expect(find.text('会议纪要'), findsOneWidget);
  });
}
