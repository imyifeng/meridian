import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor_test.dart';

import 'package:meridian/app.dart';
import 'package:meridian/editor/meridian_editor.dart';
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

  // Opens the new-memo screen, fills the title, and puts the caret in the
  // body editor ready to type.
  Future<void> startNewMemo(WidgetTester tester, String title) async {
    await tester.tap(find.byKey(const Key('new_memo_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('title_field')), title);
    await tester.tap(find.byKey(const Key('body_editor')));
    await tester.pumpAndSettle();
  }

  // Opens the editor for the memo titled [title] from the list.
  Future<void> openMemo(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  // The editor widget under test, reached through the screen's widget tree.
  MeridianEditorController controllerOf(WidgetTester tester) =>
      tester.widget<MeridianEditor>(find.byKey(const Key('body_editor'))).controller;

  // Taps a toolbar button; the toolbar scrolls horizontally, so bring the
  // button into view first.
  Future<void> tapFormat(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('Markdown 快捷输入变标题且符号不残留', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    await loginAsYifeng(tester, fake);

    await startNewMemo(tester, '快捷输入');
    await tester.typeImeText('# 会议纪要');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    // The typed "# " became a heading: the marker survives only as the
    // exported Markdown syntax, never as leftover text in the body.
    expect(fake.bodyOf('快捷输入'), '# 会议纪要');
  });

  testWidgets('工具栏可应用行内样式：加粗、斜体、删除线、行内代码、链接', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    await loginAsYifeng(tester, fake);

    await startNewMemo(tester, '行内样式');
    await tester.typeImeText('note alpha beta gamma delta echo');
    await tester.pumpAndSettle();
    final p0 = controllerOf(tester).document.getNodeAt(0)!.id;

    await tester.doubleTapInParagraph(p0, 7); // alpha
    await tapFormat(tester, 'fmt_bold');
    await tester.doubleTapInParagraph(p0, 13); // beta
    await tapFormat(tester, 'fmt_italic');
    await tester.doubleTapInParagraph(p0, 18); // gamma
    await tapFormat(tester, 'fmt_strike');
    await tester.doubleTapInParagraph(p0, 24); // delta
    await tapFormat(tester, 'fmt_code');
    await tester.doubleTapInParagraph(p0, 29); // echo
    await tapFormat(tester, 'fmt_link');
    await tester.enterText(find.byKey(const Key('link_url_field')), 'https://a.b');
    await tester.tap(find.byKey(const Key('link_apply')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    expect(fake.bodyOf('行内样式'), 'note **alpha** *beta* ~gamma~ `delta` [echo](https://a.b)');
  });

  testWidgets('工具栏可应用块级样式：H1–H3、引用、列表、待办、代码块', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    await loginAsYifeng(tester, fake);

    await startNewMemo(tester, '块级样式');

    Future<void> nextBlock(Finder fmtButton, String text) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.ensureVisible(fmtButton);
      await tester.pumpAndSettle();
      await tester.tap(fmtButton);
      await tester.pumpAndSettle();
      await tester.typeImeText(text);
      await tester.pumpAndSettle();
    }

    await tester.typeImeText('大标题'); // first block
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('fmt_h1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fmt_h1')));
    await tester.pumpAndSettle();
    await nextBlock(find.byKey(const Key('fmt_h2')), '中标题');
    await nextBlock(find.byKey(const Key('fmt_h3')), '小标题');
    await nextBlock(find.byKey(const Key('fmt_quote')), '引用句');
    await nextBlock(find.byKey(const Key('fmt_ul')), '苹果');
    await nextBlock(find.byKey(const Key('fmt_ol')), '第一');

    // 待办：勾选状态也要保存。
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('fmt_todo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fmt_todo')));
    await tester.pumpAndSettle();
    await tester.typeImeText('买菜');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    expect(fake.bodyOf('块级样式'),
        '# 大标题\n\n## 中标题\n\n### 小标题\n\n> 引用句\n\n  * 苹果\n\n  1. 第一\n\n- [x] 买菜');
  });

  testWidgets('工具栏可将段落转为代码块', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    await loginAsYifeng(tester, fake);

    await startNewMemo(tester, '代码块');
    await tester.typeImeText('print(1)');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('fmt_codeblock')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fmt_codeblock')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    expect(fake.bodyOf('代码块'), '```\nprint(1)\n```');
  });

  testWidgets('选中已有链接可移除，保存导出纯文本', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '链接笔记', body: 'see [docs](https://d.example) now');
    await loginAsYifeng(tester, fake);

    await openMemo(tester, '链接笔记');
    await tester.doubleTapInParagraph('n0', 6); // docs
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('fmt_link')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fmt_link')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('link_remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    expect(fake.bodyOf('链接笔记'), 'see docs now');
  });

  testWidgets('格式集内往返无损：原样打开再保存，正文逐字不变', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    const body = '# 标题一\n\n普通**加粗**文字\n\n> 引用\n\n- [ ] 未完成';
    fake.seedMemo('yifeng', '往返', body: body);
    await loginAsYifeng(tester, fake);

    await openMemo(tester, '往返');
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    expect(fake.bodyOf('往返'), body);
  });

  testWidgets('待办项可勾选，勾选状态被保存', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '清单', body: '- [ ] 买牛奶');
    await loginAsYifeng(tester, fake);

    await openMemo(tester, '清单');
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    expect(fake.bodyOf('清单'), '- [x] 买牛奶');
  });

  testWidgets('待办项可取消勾选，状态同样被保存', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '清单', body: '- [x] 已买牛奶');
    await loginAsYifeng(tester, fake);

    await openMemo(tester, '清单');
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    expect(fake.bodyOf('清单'), '- [ ] 已买牛奶');
  });

  testWidgets('含表格的备忘录只读展示、不崩溃，保存不破坏正文', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    const body = '# 表格\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n';
    fake.seedMemo('yifeng', '表格笔记', body: body);
    await loginAsYifeng(tester, fake);

    await openMemo(tester, '表格笔记');
    await tester.pumpAndSettle();

    // Read-only display: a notice, no editable body, the table content
    // itself visible.
    expect(find.byKey(const Key('readonly_notice')), findsOneWidget);
    expect(find.byKey(const Key('body_editor')), findsNothing);
    expect(find.textContaining('a', findRichText: true), findsWidgets);
    expect(find.textContaining('1', findRichText: true), findsWidgets);

    // Saving (title unchanged) must not mangle the out-of-set body.
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();
    expect(fake.bodyOf('表格笔记'), body);
  });

  testWidgets('H4–H6 超出 v1 格式集，只读展示', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '深标题', body: '#### 四级标题\n');
    await loginAsYifeng(tester, fake);

    await openMemo(tester, '深标题');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('readonly_notice')), findsOneWidget);
    expect(find.byKey(const Key('body_editor')), findsNothing);
    expect(find.textContaining('四级标题', findRichText: true), findsOneWidget);
  });
}
