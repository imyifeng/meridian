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

  // Types a tag into the editor's tag field and commits it with the done
  // action, the way a keyboard's return key does.
  Future<void> typeTag(WidgetTester tester, String name) async {
    await tester.enterText(find.byKey(const Key('tag_field')), name);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets('给备忘录添加多个标签，保存后再打开可移除', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    await loginAsYifeng(tester, fake);

    await tester.tap(find.byKey(const Key('new_memo_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('title_field')), '单词本');
    await typeTag(tester, '英语');
    await typeTag(tester, '单词');
    expect(find.byKey(const Key('tag_chip_英语')), findsOneWidget);
    expect(find.byKey(const Key('tag_chip_单词')), findsOneWidget);
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    // Back on the list; reopening shows the saved tags.
    await tester.tap(find.text('单词本'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tag_chip_英语')), findsOneWidget);
    expect(find.byKey(const Key('tag_chip_单词')), findsOneWidget);

    // Removing a chip and saving removes the tag for good.
    await tester.tap(find.descendant(
      of: find.byKey(const Key('tag_chip_英语')),
      matching: find.byIcon(Icons.cancel),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tag_chip_英语')), findsNothing);
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('单词本'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tag_chip_英语')), findsNothing,
        reason: '移除的标签不应再出现');
    expect(find.byKey(const Key('tag_chip_单词')), findsOneWidget);
  });

  testWidgets('标签补全只来自本人用过的标签', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.createUser('bob', 'bob password');
    fake.seedMemo('yifeng', '旧笔记', tags: ['英语']);
    fake.seedMemo('bob', 'bob 的笔记', tags: ['法语']);
    await loginAsYifeng(tester, fake);

    await tester.tap(find.byKey(const Key('new_memo_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('title_field')), '新笔记');
    await tester.enterText(find.byKey(const Key('tag_field')), '英');
    await tester.pumpAndSettle();

    // 英语 comes from yifeng's own history; 法语 is bob's and never shows.
    expect(find.byKey(const Key('tag_suggestion_英语')), findsOneWidget);
    expect(find.byKey(const Key('tag_suggestion_法语')), findsNothing);

    await tester.tap(find.byKey(const Key('tag_suggestion_英语')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tag_chip_英语')), findsOneWidget);
  });

  testWidgets('按标签筛选：正文无该词也命中，只见本人的标签', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.createUser('bob', 'bob password');
    // 购物's body never mentions 英语 — the tag alone must surface it.
    fake.seedMemo('yifeng', '购物', body: '牛奶、鸡蛋', tags: ['英语']);
    fake.seedMemo('yifeng', '笔记', body: '英语课上抄的');
    fake.seedMemo('bob', 'bob 的笔记', tags: ['英语', '法语']);
    await loginAsYifeng(tester, fake);

    expect(find.text('购物'), findsOneWidget);
    expect(find.text('笔记'), findsOneWidget);

    await tester.tap(find.byKey(const Key('filter_button')));
    await tester.pumpAndSettle();
    // The sheet lists yifeng's own tags only — never bob's 法语.
    expect(find.byKey(const Key('filter_tag_英语')), findsOneWidget);
    expect(find.byKey(const Key('filter_tag_法语')), findsNothing);
    await tester.tap(find.byKey(const Key('filter_tag_英语')));
    await tester.pumpAndSettle();

    expect(find.text('购物'), findsOneWidget);
    expect(find.text('笔记'), findsNothing);

    await tester.tap(find.byKey(const Key('clear_filter_button')));
    await tester.pumpAndSettle();
    expect(find.text('购物'), findsOneWidget);
    expect(find.text('笔记'), findsOneWidget);
  });
}
