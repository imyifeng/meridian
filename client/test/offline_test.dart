import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/api_client.dart';
import 'package:meridian/app.dart';
import 'package:meridian/memo_cache.dart';
import 'package:meridian/server_address_store.dart';
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

  testWidgets('全新安装（无凭据）断网时进入登录页，地址可改', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.offline = true; // 手机上编译期默认地址指向手机自身，探测必然失败

    await tester.pumpWidget(MeridianApp(
      baseUrl: 'http://127.0.0.1:8080', // 编译期默认值，全新安装无已存地址
      tokenStore: InMemoryTokenStore(),
      memoCache: InMemoryMemoCache(),
      apiClient: fake.client,
    ));
    await tester.pumpAndSettle();

    // 不再是只有重试按钮的错误死路：登录页带着可编辑的地址框，
    // 预填刚尝试过的地址，改好即可登录。
    final field = tester.widget<TextField>(
        find.byKey(const Key('server_address_field')));
    expect(field.controller!.text, 'http://127.0.0.1:8080');
    expect(find.byKey(const Key('login_button')), findsOneWidget);
    expect(find.text('无法连接服务器，请检查服务器地址后重试'), findsNothing);
  });

  testWidgets('不可达首启落在登录页：改地址登录成功，地址被记住', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.offline = true;
    final addressStore = InMemoryServerAddressStore();
    final tokens = InMemoryTokenStore();

    Future<void> openApp() async {
      await tester.pumpWidget(MeridianApp(
        baseUrl: 'http://127.0.0.1:8080',
        tokenStore: tokens,
        addressStore: addressStore,
        memoCache: InMemoryMemoCache(),
        apiClient: fake.client,
      ));
      await tester.pumpAndSettle();
    }

    await openApp();
    expect(find.byKey(const Key('login_button')), findsOneWidget);

    // 用户改上可达实例的地址，登录成功。
    fake.offline = false;
    await tester.enterText(
        find.byKey(const Key('server_address_field')), fake.url);
    await tester.enterText(find.byKey(const Key('username_field')), 'yifeng');
    await tester.enterText(
        find.byKey(const Key('password_field')), 'correct horse');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();
    expect(find.text('暂无备忘录'), findsOneWidget);
    expect(await addressStore.read(), fake.url);

    // 下次启动自动带出该地址，凭据仍有效则直达备忘录（既有行为不变）。
    await tester.pumpWidget(const SizedBox());
    await openApp();
    expect(find.byKey(const Key('login_button')), findsNothing);
    expect(find.text('暂无备忘录'), findsOneWidget);
  });

  testWidgets('有凭据但缓存快照不匹配，断网重启进入登录页', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.offline = true;

    final tokens = InMemoryTokenStore();
    await tokens.write('a-stale-token');
    final cache = InMemoryMemoCache();
    // 快照属于另一个凭据：无论断网与否都绝不能展示给别人。
    await cache.write(CachedSnapshot(
      token: 'someone-elses',
      memos: [Memo(id: 1, title: '别人的备忘录', body: '', categoryId: 1)],
      categories: [Category(id: 1, name: '未分类', isBuiltin: true)],
    ));

    await tester.pumpWidget(MeridianApp(
      baseUrl: fake.url,
      tokenStore: tokens,
      memoCache: cache,
      apiClient: fake.client,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('offline_banner')), findsNothing);
    expect(find.text('别人的备忘录'), findsNothing);
    expect(find.byKey(const Key('server_address_field')), findsOneWidget);
    expect(find.byKey(const Key('login_button')), findsOneWidget);
  });

  testWidgets('退出登录清除本地缓存，断网重启进入登录页而非显示旧内容', (tester) async {
    final (fake, tokens, cache) = await loginAndCacheOneMemo(tester);

    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login_button')), findsOneWidget);

    await restartOffline(tester, fake, tokens, cache);

    expect(find.byKey(const Key('offline_banner')), findsNothing);
    expect(find.text('购物清单'), findsNothing);
    expect(find.byKey(const Key('server_address_field')), findsOneWidget);
    expect(find.byKey(const Key('login_button')), findsOneWidget);
  });

  testWidgets('运行中断网：保存失败有明确提示，列表转入只读并自动恢复', (tester) async {
    final (fake, tokens, cache) = await loginAndCacheOneMemo(tester);

    // The network dies while the app is open; the editor that was already
    // open tries to save and must fail loudly, keeping the content.
    fake.offline = true;
    await tester.tap(find.byKey(const Key('new_memo_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('title_field')), '断网时写的');
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pump();
    expect(find.text('保存失败，请重试'), findsOneWidget);
    expect(find.text('断网时写的'), findsOneWidget,
        reason: '失败必须可见，内容不得静默丢失');

    // Leaving the editor, the list notices the outage and goes read-only.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('offline_banner')), findsOneWidget);
    final fab = tester.widget<FloatingActionButton>(
        find.byKey(const Key('new_memo_button')));
    expect(fab.onPressed, isNull);

    // Connection returns: the list recovers by itself, without the memo
    // that never made it to the server.
    fake.offline = false;
    fake.seedMemo('yifeng', '网上新增');
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('offline_banner')), findsNothing);
    expect(find.text('网上新增'), findsOneWidget);
    expect(find.text('断网时写的'), findsNothing);
  });
}
