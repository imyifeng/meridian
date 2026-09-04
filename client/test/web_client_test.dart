import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:super_editor/super_editor_test.dart';

import 'package:meridian/app.dart';
import 'package:meridian/editor/meridian_editor.dart';
import 'package:meridian/token_store.dart';

import 'fake_meridian_server.dart';

void main() {
  // Boots the app the way the Web 简易客户端 ships (T10): same-origin base
  // URL, browser-session stores, no notification surface.
  Future<void> bootWebClient(
      WidgetTester tester, FakeMeridianServer fake) async {
    await tester.pumpWidget(
      MeridianApp(
        baseUrl: '', // same origin: the server hosts this build at /web/
        tokenStore: InMemoryTokenStore(),
        apiClient: fake.client,
        webClient: true,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> loginAs(
      WidgetTester tester, String username, String password) async {
    await tester.enterText(find.byKey(const Key('username_field')), username);
    await tester.enterText(find.byKey(const Key('password_field')), password);
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();
  }

  // Opens the editor for the memo titled [title] from the list.
  Future<void> openMemo(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  testWidgets('登录后可查看备忘录列表与正文，Markdown 渲染正确', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '会议记录',
        body: '# 结论\n\n**重要**：周五上线', tags: ['工作']);

    await bootWebClient(tester, fake);
    await loginAs(tester, 'yifeng', 'correct horse');

    expect(find.text('会议记录'), findsOneWidget);
    await openMemo(tester, '会议记录');

    // The Markdown body arrives rendered: '# ' became a heading, the bold
    // run is styled, and no syntax symbol survives as text.
    final editor = tester
        .widget<MeridianEditor>(find.byKey(const Key('body_editor')))
        .controller;
    final h1 = editor.document.getNodeAt(0) as ParagraphNode;
    expect((h1.getMetadataValue('blockType') as Attribution?)?.id,
        header1Attribution.id);
    expect(h1.text.toPlainText(), '结论');
    final para = editor.document.getNodeAt(1) as ParagraphNode;
    expect(para.text.toPlainText(), '重要：周五上线');
    expect(para.text.spans.getAllAttributionsAt(0).map((a) => a.id),
        contains('bold'));

    // Tags show as chips, verbatim — never as Markdown.
    expect(find.byKey(const Key('tag_chip_工作')), findsOneWidget);
  });

  testWidgets('可编辑标题、正文、分类、标签并保存', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    final work = fake.createCategory('工作');
    fake.seedMemo('yifeng', '旧标题', body: '第一段');

    await bootWebClient(tester, fake);
    await loginAs(tester, 'yifeng', 'correct horse');
    await openMemo(tester, '旧标题');

    await tester.enterText(find.byKey(const Key('title_field')), '新标题');
    await tester.tap(find.byKey(const Key('category_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('工作').last);
    await tester.pumpAndSettle();
    // Append to the body at its end, like a cursor would.
    await tester.placeCaretInParagraph('n0', 3);
    await tester.pumpAndSettle();
    await tester.typeImeText('新增一句');
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tag_field')), '英语');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    // Back on the list: the new title under the new category.
    expect(find.text('新标题'), findsOneWidget);
    expect(find.text('工作'), findsOneWidget);
    expect(fake.bodyOf('新标题'), '第一段新增一句');
    expect(fake.memoByTitle('新标题')['tags'], <String>['英语']);
    expect(fake.memoByTitle('新标题')['category_id'], work['id']);
  });

  testWidgets('Web 端不出现提醒功能入口，已有提醒保存后原样保留', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    final when = DateTime(2027, 3, 1, 9, 30);
    fake.seedMemo('yifeng', '带提醒', body: '正文', remindAt: when);

    await bootWebClient(tester, fake);
    await loginAs(tester, 'yifeng', 'correct horse');
    await openMemo(tester, '带提醒');

    // Reminders are a 客户端 feature: the Web 简易客户端 offers no way to
    // set, change, or clear one.
    expect(find.byKey(const Key('reminder_section')), findsNothing);
    expect(find.byKey(const Key('set_reminder_button')), findsNothing);
    expect(find.text('设置提醒'), findsNothing);

    // A simple edit saves without touching the standing reminder.
    await tester.enterText(find.byKey(const Key('title_field')), '改名后');
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();
    expect(fake.remindAtOf('改名后'), when);
  });

  testWidgets('Web 端同源托管：登录页没有服务器地址栏，登录直达列表', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');

    await bootWebClient(tester, fake);

    // The instance is whatever origin served the page — no address to type.
    expect(find.text('服务器地址'), findsNothing);
    await loginAs(tester, 'yifeng', 'correct horse');
    expect(find.text('暂无备忘录'), findsOneWidget);
  });

  testWidgets('宽窗口下登录表单居中限宽，不横向拉满', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');

    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await bootWebClient(tester, fake);

    final width = tester.getSize(find.byKey(const Key('username_field'))).width;
    expect(width, lessThanOrEqualTo(360),
        reason: '浏览器窗口很宽时，表单应当限宽居中而不是拉满整行');
  });
}
