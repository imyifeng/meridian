import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/app.dart';
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

  // The row's preview text, read off the rendered list.
  Text previewOf(WidgetTester tester, String title) {
    final row = tester.widget<ListTile>(
      find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
    );
    return row.subtitle! as Text;
  }

  testWidgets('列表摘要直接显示纯文本正文，按一行截断', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    const body = '# 会议纪要\n**重要**：周五上线\n- 第一项';
    fake.seedMemo('yifeng', '格式丰富的笔记', body: body);
    await pumpAndLogin(tester, app(fake), 'yifeng', 'correct horse');

    final preview = previewOf(tester, '格式丰富的笔记');

    // ADR-0008: the summary is the body itself, no Markdown awareness —
    // symbols show literally and are clipped by the row, not stripped.
    expect(preview.data, body);
    expect(preview.maxLines, 1);
    expect(preview.overflow, TextOverflow.ellipsis);
  });

  testWidgets('回收站列表的摘要同样直接显示正文', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    const body = '## 小标题\n**加粗**与`行内代码`';
    fake.seedMemo('yifeng', '被删的笔记', body: body);
    await pumpAndLogin(tester, app(fake), 'yifeng', 'correct horse');

    // Delete it into the recycle bin, then open the bin.
    await tester.tap(find.text('被删的笔记'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trash_button')));
    await tester.pumpAndSettle();

    final preview = previewOf(tester, '被删的笔记');
    expect(preview.data, body);
    expect(preview.maxLines, 1);
    expect(preview.overflow, TextOverflow.ellipsis);
  });
}
