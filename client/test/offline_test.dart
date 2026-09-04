import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/app.dart';
import 'package:meridian/memo_cache.dart';
import 'package:meridian/token_store.dart';

import 'fake_meridian_server.dart';

void main() {
  // Logs in with one seeded memo so the local cache fills, the precondition
  // for every offline scenario below.
  Future<(FakeMeridianServer, InMemoryTokenStore, InMemoryMemoCache)>
      loginAndCacheOneMemo(WidgetTester tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '购物清单', body: '牛奶、鸡蛋');

    final tokens = InMemoryTokenStore();
    final cache = InMemoryMemoCache();

    await tester.pumpWidget(MeridianApp(
      baseUrl: fake.url,
      tokenStore: tokens,
      memoCache: cache,
      apiClient: fake.client,
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('username_field')), 'yifeng');
    await tester.enterText(find.byKey(const Key('password_field')), 'correct horse');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();
    expect(find.text('购物清单'), findsOneWidget);
    return (fake, tokens, cache);
  }

  Future<void> restartOffline(WidgetTester tester, FakeMeridianServer fake,
      InMemoryTokenStore tokens, InMemoryMemoCache cache) async {
    fake.offline = true; // the network dies before the restart
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MeridianApp(
      baseUrl: fake.url,
      tokenStore: tokens,
      memoCache: cache,
      apiClient: fake.client,
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('无网重启后已缓存的备忘录仍可查看，界面明确只读', (tester) async {
    final (fake, tokens, cache) = await loginAndCacheOneMemo(tester);

    await restartOffline(tester, fake, tokens, cache);

    // Straight into the cached memo list — no login, no connection error.
    expect(find.byKey(const Key('login_button')), findsNothing);
    expect(find.byKey(const Key('offline_banner')), findsOneWidget);
    expect(find.text('购物清单'), findsOneWidget);
    expect(find.text('牛奶、鸡蛋'), findsOneWidget);
  });

  testWidgets('离线时创建与编辑入口禁用，备忘录只能只读查看', (tester) async {
    final (fake, tokens, cache) = await loginAndCacheOneMemo(tester);
    await restartOffline(tester, fake, tokens, cache);

    // The create entry is disabled: tapping it opens no editor.
    final fab = tester.widget<FloatingActionButton>(
        find.byKey(const Key('new_memo_button')));
    expect(fab.onPressed, isNull);
    await tester.tap(find.byKey(const Key('new_memo_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('title_field')), findsNothing);

    // Tapping a cached memo opens a read-only view: no save, no delete,
    // no editable field anywhere.
    await tester.tap(find.text('购物清单'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('save_button')), findsNothing);
    expect(find.byKey(const Key('delete_button')), findsNothing);
    expect(find.byKey(const Key('tag_field')), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('恢复联网后自动刷新到最新数据', (tester) async {
    final (fake, tokens, cache) = await loginAndCacheOneMemo(tester);
    await restartOffline(tester, fake, tokens, cache);
    expect(find.byKey(const Key('offline_banner')), findsOneWidget);

    // A new memo lands on the server while we are cut off; nothing shows
    // until the connection returns.
    fake.seedMemo('yifeng', '网上新增');
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('网上新增'), findsNothing);

    fake.offline = false;
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    // Back online by itself: banner gone, latest data in, create entry
    // re-enabled.
    expect(find.byKey(const Key('offline_banner')), findsNothing);
    expect(find.text('网上新增'), findsOneWidget);
    expect(find.text('购物清单'), findsOneWidget);
    final fab = tester.widget<FloatingActionButton>(
        find.byKey(const Key('new_memo_button')));
    expect(fab.onPressed, isNotNull);
  });

  testWidgets('从没登录过（无缓存）断网时提示无法连接', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.offline = true;

    await tester.pumpWidget(MeridianApp(
      baseUrl: fake.url,
      tokenStore: InMemoryTokenStore(),
      memoCache: InMemoryMemoCache(),
      apiClient: fake.client,
    ));
    await tester.pumpAndSettle();

    expect(find.text('无法连接服务器，请检查服务器地址后重试'), findsOneWidget);
  });

  testWidgets('退出登录清除本地缓存，断网重启不再显示内容', (tester) async {
    final (fake, tokens, cache) = await loginAndCacheOneMemo(tester);

    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login_button')), findsOneWidget);

    await restartOffline(tester, fake, tokens, cache);

    expect(find.byKey(const Key('offline_banner')), findsNothing);
    expect(find.text('购物清单'), findsNothing);
    expect(find.text('无法连接服务器，请检查服务器地址后重试'), findsOneWidget);
  });
}
