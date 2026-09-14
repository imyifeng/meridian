import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/app.dart';
import 'package:meridian/memo_cache.dart';
import 'package:meridian/token_store.dart';

import 'fake_meridian_server.dart';

// The 搜索 page (#72): full-text search lives on its own tab — enter, type,
// results. The IndexedStack keeps the home list mounted alongside it, so
// every result assertion scopes to the page's own list (search_results).

Finder _inResults(String title) => find.descendant(
    of: find.byKey(const Key('search_results')), matching: find.text(title));

Finder _navLabel(String label) => find.descendant(
    of: find.byKey(const Key('nav_bar')), matching: find.text(label));

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

  // Onto the search tab, then a query committed the way a keyboard's
  // return key does.
  Future<void> search(WidgetTester tester, String query) async {
    await tester.tap(_navLabel('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('search_field')), query);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
  }

  testWidgets('搜索命中标题、正文与标签，结果只含本人的备忘录', (tester) async {
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
    expect(_inResults('英语学习笔记'), findsOneWidget,
        reason: '标题子串命中，且只应命中 yifeng 自己的，bob 的不出现');
    expect(_inResults('周末安排'), findsOneWidget, reason: '标签命中');
    expect(_inResults('购物清单'), findsNothing);

    // 中文正文子串也命中。
    await search(tester, '五十');
    expect(_inResults('英语学习笔记'), findsOneWidget);

    // 换个词，正文来源也能命中。
    await search(tester, 'abandon');
    expect(_inResults('购物清单'), findsOneWidget);
    expect(_inResults('英语学习笔记'), findsNothing);

    // 清空搜索，结果页退回初始提示。
    await tester.tap(find.byKey(const Key('clear_search_button')));
    await tester.pumpAndSettle();
    expect(find.text('输入关键词搜索备忘录'), findsOneWidget);
    expect(find.byKey(const Key('search_results')), findsNothing);
  });

  testWidgets('输入停顿即自动搜索，无需按回车', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '英语学习笔记', body: '今天背了五十个词');
    await loginAsYifeng(tester, fake);

    await tester.tap(_navLabel('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('search_field')), '英语');

    // The 300ms debounce has not elapsed: no search yet.
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('search_results')), findsNothing);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(_inResults('英语学习笔记'), findsOneWidget);
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
    expect(_inResults('会议纪要'), findsNothing);
    expect(find.text('未找到匹配的备忘录'), findsOneWidget);

    // 恢复后重新可搜。
    await tester.tap(find.byKey(const Key('clear_search_button')));
    await tester.pumpAndSettle();
    await tester.tap(_navLabel('首页'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trash_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore_button_1')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    await search(tester, '交付');
    expect(_inResults('会议纪要'), findsOneWidget);
  });

  testWidgets('关键词可与标签、分类筛选叠加，各自独立清除', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    final work = fake.createCategory('工作');
    fake.seedMemo('yifeng', '工作A',
        body: '晨会记录', categoryId: work['id'] as int, tags: ['英语']);
    fake.seedMemo('yifeng', '工作B', body: '晨会记录', categoryId: work['id'] as int);
    // 工作E shares the tag and category with 工作A but its body never
    // mentions the keyword — it only surfaces once the keyword is gone.
    fake.seedMemo('yifeng', '工作E',
        body: '无关内容', categoryId: work['id'] as int, tags: ['英语']);
    // 生活C shares the tag and the keyword with 工作A but lives in 未分类.
    fake.seedMemo('yifeng', '生活C', body: '晨会记录', tags: ['英语']);
    fake.seedMemo('yifeng', '随手记', body: '晨会记录');
    await loginAsYifeng(tester, fake);

    await search(tester, '晨会');
    expect(_inResults('工作A'), findsOneWidget);
    expect(_inResults('工作B'), findsOneWidget);
    expect(_inResults('生活C'), findsOneWidget);
    expect(_inResults('随手记'), findsOneWidget);
    expect(_inResults('工作E'), findsNothing);

    // 关键词 + 分类：生活C 与 随手记 出局。
    await tester.tap(find.byKey(const Key('search_category_filter_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter_category_工作')));
    await tester.pumpAndSettle();
    expect(_inResults('工作A'), findsOneWidget);
    expect(_inResults('工作B'), findsOneWidget);
    expect(_inResults('生活C'), findsNothing);
    expect(_inResults('随手记'), findsNothing);

    // 再叠加标签：三重筛选下只剩 工作A。
    await tester.tap(find.byKey(const Key('search_filter_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter_tag_英语')));
    await tester.pumpAndSettle();
    expect(_inResults('工作A'), findsOneWidget);
    expect(_inResults('工作B'), findsNothing);

    // 清空关键词，分类与标签仍在起作用：工作E 因不匹配关键词依旧出局。
    await tester.enterText(find.byKey(const Key('search_field')), '');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(_inResults('工作A'), findsOneWidget);
    expect(_inResults('工作E'), findsOneWidget);
    expect(_inResults('工作B'), findsNothing);

    // 删掉标签片，分类继续生效。
    await tester.tap(find.byKey(const Key('search_filter_chip')));
    await tester.pumpAndSettle();
    expect(_inResults('工作A'), findsOneWidget);
    expect(_inResults('工作B'), findsOneWidget);
    expect(_inResults('工作E'), findsOneWidget);

    // 删掉分类片，一切筛选退场，回到初始提示。
    await tester.tap(find.byKey(const Key('search_category_filter_chip')));
    await tester.pumpAndSettle();
    expect(find.text('输入关键词搜索备忘录'), findsOneWidget);
    expect(find.byKey(const Key('search_results')), findsNothing);
  });

  testWidgets('点击搜索结果进入只读查看页', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '英语学习笔记', body: '今天背了五十个词', tags: ['日常']);
    await loginAsYifeng(tester, fake);

    await search(tester, '五十');
    await tester.tap(_inResults('英语学习笔记'));
    await tester.pumpAndSettle();

    // The reader, not the editor: title, tags, and the plain-text body.
    expect(find.text('查看备忘录'), findsOneWidget);
    expect(find.byKey(const Key('body_readonly')), findsOneWidget);
    expect(find.byKey(const Key('tag_chip_日常')), findsOneWidget);
    expect(find.byKey(const Key('title_field')), findsNothing);

    // Back: the results are still there.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(_inResults('英语学习笔记'), findsOneWidget);
  });

  testWidgets('离线启动时搜索页明确不可用，恢复联网后自动回到可用', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '英语学习笔记', body: '今天背了五十个词');
    final cache = InMemoryMemoCache();
    final tokens = InMemoryTokenStore();

    Future<void> boot() async {
      await tester.pumpWidget(MeridianApp(
        baseUrl: fake.url,
        tokenStore: tokens,
        memoCache: cache,
        apiClient: fake.client,
      ));
      await tester.pumpAndSettle();
    }

    // 先联网登录，把快照写进缓存，再断网重启。
    await boot();
    await tester.enterText(find.byKey(const Key('username_field')), 'yifeng');
    await tester.enterText(find.byKey(const Key('password_field')), 'correct horse');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();

    fake.offline = true;
    await tester.pumpWidget(const SizedBox());
    await boot();

    await tester.tap(_navLabel('搜索'));
    await tester.pumpAndSettle();

    // 搜索走服务器，离线时明确不可用：输入框禁用，页面明说。
    expect(find.text('离线模式：暂不可搜索，恢复联网后自动恢复'), findsOneWidget);
    final field = tester.widget<TextField>(find.byKey(const Key('search_field')));
    expect(field.enabled, isFalse);

    // The home tab keeps its own offline banner; the search page's notice
    // is its own (both tabs stay mounted in the IndexedStack).
    expect(find.byKey(const Key('search_offline_banner')), findsOneWidget);

    fake.offline = false;
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    // Back online by itself: the field is live again, nothing says offline.
    final live = tester.widget<TextField>(find.byKey(const Key('search_field')));
    expect(live.enabled, isTrue);
    expect(find.byKey(const Key('search_offline_banner')), findsNothing);
    expect(find.text('输入关键词搜索备忘录'), findsOneWidget);
  });

  testWidgets('运行中断网：搜索转入不可用，恢复后原查询自动重跑', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '英语学习笔记', body: '今天背了五十个词');
    await loginAsYifeng(tester, fake);

    await search(tester, '英语');
    expect(_inResults('英语学习笔记'), findsOneWidget);

    // The network dies; the next keystroke's search fails into offline.
    fake.offline = true;
    await tester.enterText(find.byKey(const Key('search_field')), '五十');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('离线模式：暂不可搜索，恢复联网后自动恢复'), findsOneWidget);
    final field = tester.widget<TextField>(find.byKey(const Key('search_field')));
    expect(field.enabled, isFalse);

    // The connection returns: the standing query re-runs on its own.
    fake.offline = false;
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search_offline_banner')), findsNothing);
    expect(_inResults('英语学习笔记'), findsOneWidget);
  });
}
