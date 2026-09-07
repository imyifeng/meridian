import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/app.dart';
import 'package:meridian/token_store.dart';

import 'fake_meridian_server.dart';

void main() {
  // The row's preview text, read off the rendered list.
  Text previewOf(WidgetTester tester, String title) {
    final row = tester.widget<ListTile>(
      find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
    );
    return row.subtitle! as Text;
  }

  testWidgets('列表预览显示纯文本摘要，不出现 Markdown 源符号', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '格式丰富的笔记', body: '# 会议纪要\n\n**重要**决定\n\n'
        '- 第一项\n- 第二项\n\n```\nprint(1)\n```\n\n'
        '| 甲 | 乙 |\n| --- | --- |\n| 一 | 二 |\n');
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

    final preview = previewOf(tester, '格式丰富的笔记').data!;

    // The rendered text of every block survives, syntax symbols do not.
    for (final word in ['会议纪要', '重要决定', '第一项', '第二项', 'print(1)', '甲', '乙', '一', '二']) {
      expect(preview, contains(word), reason: '预览缺少「$word」：$preview');
    }
    for (final symbol in ['#', '*', '`', '|', '-', '~', '>', '[', ']']) {
      expect(preview, isNot(contains(symbol)), reason: '预览泄漏了「$symbol」：$preview');
    }
    // Multi-line bodies collapse into a single-paragraph summary.
    expect(preview, isNot(contains('\n')));
  });

  testWidgets('回收站列表的预览同样只显示纯文本摘要', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '被删的笔记', body: '## 小标题\n\n**加粗**与`行内代码`\n');
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

    // Delete it into the recycle bin, then open the bin.
    await tester.tap(find.text('被删的笔记'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trash_button')));
    await tester.pumpAndSettle();

    final row = tester.widget<ListTile>(
      find.ancestor(of: find.text('被删的笔记'), matching: find.byType(ListTile)),
    );
    final preview = row.subtitle! as Text;

    expect(preview.data, contains('小标题'));
    expect(preview.data, contains('加粗与行内代码'));
    for (final symbol in ['#', '*', '`']) {
      expect(preview.data, isNot(contains(symbol)), reason: '回收站预览泄漏了「$symbol」');
    }
  });
}
