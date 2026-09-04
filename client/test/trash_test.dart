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

  // Opens the memo's editor and confirms the delete dialog, standing in for
  // the user tossing a memo into the recycle bin.
  Future<void> deleteFromEditor(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('delete_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
  }

  // Ids are handed out sequentially, so the first seeded memo is /1/.
  const memoId = 1;

  testWidgets('删除备忘录进回收站，恢复后回到原分类', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    final work = fake.createCategory('工作');
    fake.seedMemo('yifeng', '会议纪要',
        body: '下周一交付', tags: ['英语'], categoryId: work['id'] as int);
    await loginAsYifeng(tester, fake);

    // 删除：从列表消失。
    await tester.tap(find.text('会议纪要'));
    await tester.pumpAndSettle();
    await deleteFromEditor(tester);
    expect(find.text('会议纪要'), findsNothing);

    // 出现在回收站。
    await tester.tap(find.byKey(const Key('trash_button')));
    await tester.pumpAndSettle();
    expect(find.text('会议纪要'), findsOneWidget);

    // 恢复：离开回收站。
    await tester.tap(find.byKey(const Key('restore_button_$memoId')));
    await tester.pumpAndSettle();
    expect(find.text('会议纪要'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 回到列表，仍在原分类。
    expect(find.text('会议纪要'), findsOneWidget);
    expect(find.text('工作'), findsOneWidget);
  });

  testWidgets('回收站里的备忘录不出现在列表与标签筛选', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '购物', body: '牛奶、鸡蛋', tags: ['英语']);
    await loginAsYifeng(tester, fake);

    await tester.tap(find.text('购物'));
    await tester.pumpAndSettle();
    await deleteFromEditor(tester);

    await tester.tap(find.byKey(const Key('filter_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('filter_tag_英语')), findsNothing,
        reason: '回收站备忘录的标签不进补全');
    await tester.tapAt(const Offset(10, 10)); // 收起筛选弹层
    await tester.pumpAndSettle();

    expect(find.text('购物'), findsNothing);
  });

  testWidgets('彻底删除后不可恢复', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '草稿');
    await loginAsYifeng(tester, fake);

    await tester.tap(find.text('草稿'));
    await tester.pumpAndSettle();
    await deleteFromEditor(tester);

    await tester.tap(find.byKey(const Key('trash_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('purge_button_$memoId')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('草稿'), findsNothing);
    expect(find.text('回收站是空的'), findsOneWidget);
  });
}
