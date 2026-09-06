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

  // Commits the search field's text the way a keyboard's return key does.
  Future<void> submitSearch(WidgetTester tester, String query) async {
    await tester.enterText(find.byKey(const Key('search_field')), query);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets('按分类筛选：正文无分类名也命中，未分类可筛，清除后恢复', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    final work = fake.createCategory('工作');
    // 购物's text never mentions 工作 — the assignment alone must surface it.
    fake.seedMemo('yifeng', '购物', body: '牛奶、鸡蛋', categoryId: work['id'] as int);
    fake.seedMemo('yifeng', '随手记');
    await loginAsYifeng(tester, fake);

    expect(find.text('购物'), findsOneWidget);
    expect(find.text('随手记'), findsOneWidget);

    await tester.tap(find.byKey(const Key('category_filter_button')));
    await tester.pumpAndSettle();
    // The sheet offers the whole taxonomy, built-in 未分类 included.
    expect(find.byKey(const Key('filter_category_工作')), findsOneWidget);
    expect(find.byKey(const Key('filter_category_未分类')), findsOneWidget);
    await tester.tap(find.byKey(const Key('filter_category_工作')));
    await tester.pumpAndSettle();

    expect(find.text('购物'), findsOneWidget);
    expect(find.text('随手记'), findsNothing);
    expect(find.text('分类：工作'), findsOneWidget);

    // The built-in is a filter like any other (Story 5: it is where new
    // memos start, so it must stay reachable).
    await tester.tap(find.byKey(const Key('category_filter_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter_category_未分类')));
    await tester.pumpAndSettle();
    expect(find.text('随手记'), findsOneWidget);
    expect(find.text('购物'), findsNothing);
    expect(find.text('分类：未分类'), findsOneWidget);

    await tester.tap(find.byKey(const Key('clear_category_filter_button')));
    await tester.pumpAndSettle();
    expect(find.text('购物'), findsOneWidget);
    expect(find.text('随手记'), findsOneWidget);
    expect(find.text('Meridian'), findsOneWidget);
  });

  testWidgets('分类筛选与标签筛选、搜索共存，各自独立清除', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    final work = fake.createCategory('工作');
    fake.seedMemo('yifeng', '工作A',
        body: '晨会记录', categoryId: work['id'] as int, tags: ['英语']);
    fake.seedMemo('yifeng', '工作B', categoryId: work['id'] as int);
    // 生活C shares the tag and the search word with 工作A but lives in
    // 未分类 — the category filter is what keeps it out below.
    fake.seedMemo('yifeng', '生活C', body: '晨会记录', tags: ['英语']);
    await loginAsYifeng(tester, fake);

    await tester.tap(find.byKey(const Key('category_filter_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter_category_工作')));
    await tester.pumpAndSettle();
    expect(find.text('工作A'), findsOneWidget);
    expect(find.text('工作B'), findsOneWidget);
    expect(find.text('生活C'), findsNothing);

    // The tag filter stacks on top of the category.
    await tester.tap(find.byKey(const Key('filter_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter_tag_英语')));
    await tester.pumpAndSettle();
    expect(find.text('工作A'), findsOneWidget);
    expect(find.text('工作B'), findsNothing);
    expect(find.text('分类：工作 · 标签：英语'), findsOneWidget);

    // Clearing the tag keeps the category.
    await tester.tap(find.byKey(const Key('clear_filter_button')));
    await tester.pumpAndSettle();
    expect(find.text('工作A'), findsOneWidget);
    expect(find.text('工作B'), findsOneWidget);
    expect(find.text('生活C'), findsNothing);

    // Search runs inside the category: 生活C carries 晨会记录 too but is out
    // of scope.
    await tester.tap(find.byKey(const Key('search_button')));
    await tester.pumpAndSettle();
    await submitSearch(tester, '晨会');
    expect(find.text('工作A'), findsOneWidget);
    expect(find.text('工作B'), findsNothing);
    expect(find.text('生活C'), findsNothing);

    // Exiting search restores the category-filtered list.
    await tester.tap(find.byKey(const Key('clear_search_button')));
    await tester.pumpAndSettle();
    expect(find.text('工作A'), findsOneWidget);
    expect(find.text('工作B'), findsOneWidget);
    expect(find.text('分类：工作'), findsOneWidget);
  });
}
