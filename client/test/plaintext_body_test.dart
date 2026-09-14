import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/api_client.dart';
import 'package:meridian/app.dart';
import 'package:meridian/screens/memo_view_screen.dart';
import 'package:meridian/theme.dart';
import 'package:meridian/token_store.dart';

import 'fake_meridian_server.dart';
import 'login_harness.dart';

void main() {
  // The client app wired to [fake], booted the way production does.
  MeridianApp app(FakeMeridianServer fake) => MeridianApp(
        baseUrl: fake.url,
        tokenStore: InMemoryTokenStore(),
        apiClient: fake.client,
      );

  // The body field of the open memo editor, as an ordinary text input.
  TextField bodyField(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(const Key('body_editor')));

  testWidgets('新建备忘录正文按纯文本保存，#、* 等符号逐字保留', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    await pumpAndLogin(tester, app(fake), 'yifeng', 'correct horse');

    await tester.tap(find.byKey(const Key('new_memo_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('title_field')), '速记');
    await tester.enterText(
        find.byKey(const Key('body_editor')), '# 会议纪要\n**重要**：周五上线');
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    // ADR-0008: the body is plain text — no Markdown conversion on save,
    // every syntax symbol survives byte for byte.
    expect(fake.bodyOf('速记'), '# 会议纪要\n**重要**：周五上线');
  });

  testWidgets('旧备忘录打开：正文原样显示在文本框，再保存逐字不变', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    const body = '# 标题\n\n**加粗**与`代码`';
    fake.seedMemo('yifeng', '旧笔记', body: body);
    await pumpAndLogin(tester, app(fake), 'yifeng', 'correct horse');

    await tester.tap(find.text('旧笔记'));
    await tester.pumpAndSettle();

    // Stored Markdown symbols are shown literally, no migration needed.
    expect(bodyField(tester).controller!.text, body);

    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();
    expect(fake.bodyOf('旧笔记'), body);
  });

  testWidgets('查看页按字面显示正文，不渲染 Markdown', (tester) async {
    const body = '# 标题\n**加粗**与`代码`';
    await tester.pumpWidget(MaterialApp(
      theme: meridianLightTheme,
      darkTheme: meridianDarkTheme,
      home: MemoViewScreen(
        memo: Memo(id: 1, title: '旧笔记', body: body, categoryId: 1),
      ),
    ));
    await tester.pumpAndSettle();

    // The body shows as stored, symbols included (ADR-0008) — the heading
    // marker and emphasis stars are text, not formatting.
    expect(find.text(body), findsOneWidget);
  });

  testWidgets('查看页长正文可滚动查看，末尾内容可达', (tester) async {
    final body = List.generate(200, (i) => '第$i行正文').join('\n');
    await tester.pumpWidget(MaterialApp(
      theme: meridianLightTheme,
      darkTheme: meridianDarkTheme,
      home: MemoViewScreen(
        memo: Memo(id: 1, title: '长文', body: body, categoryId: 1),
      ),
    ));
    await tester.pumpAndSettle();

    // However long, the whole body stays in the tree — nothing is dropped.
    expect(find.text(body), findsOneWidget);

    // Before scrolling, the tail hangs below the viewport (the default
    // test surface is 800×600) instead of being silently clipped.
    expect(
      tester.getBottomRight(find.byKey(const Key('body_readonly'))).dy,
      greaterThan(600),
    );

    // Scrolling to the end brings the tail into view. The drag targets the
    // viewport: the body Text's own center is off-screen by construction.
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -10000));
    await tester.pumpAndSettle();
    expect(
      tester.getBottomRight(find.byKey(const Key('body_readonly'))).dy,
      lessThanOrEqualTo(600),
    );
  });
}
