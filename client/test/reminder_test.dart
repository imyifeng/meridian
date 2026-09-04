import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/api_client.dart';
import 'package:meridian/app.dart';
import 'package:meridian/memo_cache.dart';
import 'package:meridian/reminders.dart';
import 'package:meridian/token_store.dart';

import 'fake_meridian_server.dart';

/// Recording stand-in for the platform notification surface (Windows toast /
/// Android notification): the injected fake the spec names as the seam for
/// verifying scheduling decisions — which memo gets a notice, and when.
class FakeReminderNotifications implements ReminderNotifications {
  final List<Memo> shown = [];
  int inits = 0;
  void Function(int memoId)? _onTap;

  /// Simulates the user tapping a reminder notification.
  void tap(int memoId) => _onTap?.call(memoId);

  @override
  Future<void> init({required void Function(int memoId) onTap}) async {
    _onTap = onTap;
    inits++;
  }

  @override
  Future<void> showDueReminder(Memo memo) async => shown.add(memo);
}

void main() {
  // Boots the app on the fake instance with a fake notification surface and
  // a controllable clock, signing in as yifeng.
  Future<FakeReminderNotifications> loginAsYifeng(
    WidgetTester tester,
    FakeMeridianServer fake, {
    DateTime Function()? now,
    MemoCache? cache,
    InMemoryTokenStore? tokenStore,
  }) async {
    final notifications = FakeReminderNotifications();
    await tester.pumpWidget(
      MeridianApp(
        baseUrl: fake.url,
        tokenStore: tokenStore ?? InMemoryTokenStore(),
        apiClient: fake.client,
        memoCache: cache,
        reminderNotifications: notifications,
        reminderNow: now,
      ),
    );
    await tester.pump();
    await tester.enterText(find.byKey(const Key('username_field')), 'yifeng');
    await tester.enterText(find.byKey(const Key('password_field')), 'correct horse');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    return notifications;
  }

  // Drives the real date and time pickers: today, at [hour]:[minute].
  // Finders stay scoped to the dialogs — the editor underneath has TextFields
  // of its own.
  Future<void> drivePickers(WidgetTester tester,
      {required String hour, required String minute}) async {
    await tester.tap(find.descendant(
      of: find.byType(CalendarDatePicker),
      matching: find.text('${DateTime.now().day}'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(DatePickerDialog),
      matching: find.text('OK'),
    ));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.first, hour);
    await tester.enterText(fields.last, minute);
    // The test locale is 12-hour; AM keeps the typed morning hour honest.
    if (find.text('AM').evaluate().isNotEmpty) {
      await tester.tap(find.text('AM'));
      await tester.pump();
    }
    await tester.tap(find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.text('OK'),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> pickReminder(WidgetTester tester,
      {String hour = '08', String minute = '30'}) async {
    await tester.tap(find.byKey(const Key('set_reminder_button')));
    await tester.pumpAndSettle();
    await drivePickers(tester, hour: hour, minute: minute);
  }

  String two(int n) => n.toString().padLeft(2, '0');
  final today0830 =
      '${DateTime.now().year}-${two(DateTime.now().month)}-${two(DateTime.now().day)} 08:30';

  String? valueText(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('reminder_value'))).data;

  testWidgets('设置提醒：保存后可见，重开编辑器同一提醒', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    await loginAsYifeng(tester, fake);

    await tester.tap(find.byKey(const Key('new_memo_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('title_field')), '交房租');
    await pickReminder(tester);
    expect(valueText(tester), today0830);
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    // The reminder went to the server as part of the memo.
    expect(fake.remindAtOf('交房租'), isNotNull);

    // Reopening shows the same reminder — it lives on the memo.
    await tester.tap(find.text('交房租'));
    await tester.pumpAndSettle();
    expect(valueText(tester), today0830);
  });

  testWidgets('修改与取消提醒：保存后服务器上是新状态', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    await loginAsYifeng(tester, fake);

    await tester.tap(find.byKey(const Key('new_memo_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('title_field')), '交房租');
    await pickReminder(tester);
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('交房租'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('change_reminder_button')));
    await tester.pumpAndSettle();
    await drivePickers(tester, hour: '09', minute: '45');
    expect(valueText(tester),
        '${today0830.substring(0, 11)}09:45');
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();
    final changed = fake.remindAtOf('交房租')!;
    expect(changed.hour, 9);
    expect(changed.minute, 45);

    // Cancelling clears it for good.
    await tester.tap(find.text('交房租'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('clear_reminder_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reminder_value')), findsNothing);
    expect(find.byKey(const Key('set_reminder_button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();
    expect(fake.remindAtOf('交房租'), isNull);
  });

  testWidgets('其他设备设置的提醒出现在列表与查看页', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '开会',
        remindAt: DateTime(2026, 9, 10, 9, 0));
    await loginAsYifeng(tester, fake);

    // The list marks the reminder; opening the memo shows it read-only in
    // the editor too.
    expect(find.byIcon(Icons.alarm), findsOneWidget);
    await tester.tap(find.text('开会'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reminder_value')), findsOneWidget);
    expect(find.textContaining('2026-09-10 09:00'), findsOneWidget);
  });

  testWidgets('到期触发：运行中的客户端弹本地通知，点按打开该备忘录', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    var clock = DateTime(2026, 9, 4, 12, 0, 0);
    fake.seedMemo('yifeng', '开会', remindAt: clock.add(const Duration(seconds: 30)));
    final notifications = await loginAsYifeng(tester, fake, now: () => clock);
    expect(notifications.shown, isEmpty, reason: '未到期不应通知');

    // The due moment passes while the app keeps running.
    clock = clock.add(const Duration(minutes: 2));
    await tester.pump(const Duration(seconds: 16));

    expect(notifications.shown, hasLength(1));
    expect(notifications.shown.single.title, '开会');

    // Tapping the notice opens that memo.
    notifications.tap(notifications.shown.single.id);
    await tester.pumpAndSettle();
    final titleField =
        tester.widget<TextField>(find.byKey(const Key('title_field')));
    expect(titleField.controller!.text, '开会');
  });

  testWidgets('打开时已过期的提醒不再触发；被取消的提醒解除调度', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    var clock = DateTime(2026, 9, 4, 12, 0, 0);
    // Already past when this client first sees it: old news, no pop.
    fake.seedMemo('yifeng', '旧提醒', remindAt: clock.subtract(const Duration(hours: 3)));
    final notifications = await loginAsYifeng(tester, fake, now: () => clock);
    await tester.pump(const Duration(seconds: 16));
    expect(notifications.shown, isEmpty);

    // A future reminder that is then cancelled from (another device's) edit
    // never fires.
    fake.seedMemo('yifeng', '开会', remindAt: clock.add(const Duration(seconds: 30)));
    await tester.tap(find.byKey(const Key('search_button')));
    await tester.pumpAndSettle();
    // An empty search commits as "show everything" and reloads the list.
    await tester.enterText(find.byKey(const Key('search_field')), '旧提醒');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byKey(const Key('search_field')), '');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(seconds: 1));
    fake.setMemoReminder('yifeng', '开会', null);
    // Reload again so the cleared reminder reaches the scheduler.
    await tester.enterText(find.byKey(const Key('search_field')), '开会');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byKey(const Key('search_field')), '');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(seconds: 1));

    clock = clock.add(const Duration(minutes: 2));
    await tester.pump(const Duration(seconds: 16));
    expect(notifications.shown, isEmpty, reason: '已取消的提醒不应触发');
  });

  testWidgets('提醒随缓存离线可见；离线中到期仍触发', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    var clock = DateTime(2026, 9, 4, 12, 0, 0);
    fake.seedMemo('yifeng', '开会', remindAt: clock.add(const Duration(seconds: 30)));
    final cache = InMemoryMemoCache();
    final tokenStore = InMemoryTokenStore();
    var notifications = await loginAsYifeng(tester, fake,
        now: () => clock, cache: cache, tokenStore: tokenStore);

    // The network dies; a fresh run boots on the cache, reminder intact.
    fake.offline = true;
    notifications = FakeReminderNotifications();
    await tester.pumpWidget(const SizedBox()); // tear down the first run
    await tester.pumpWidget(
      MeridianApp(
        baseUrl: fake.url,
        tokenStore: tokenStore,
        apiClient: fake.client,
        memoCache: cache,
        reminderNotifications: notifications,
        reminderNow: () => clock,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('offline_banner')), findsOneWidget);
    expect(find.byIcon(Icons.alarm), findsOneWidget);

    clock = clock.add(const Duration(minutes: 2));
    await tester.pump(const Duration(seconds: 16));
    expect(notifications.shown.map((m) => m.title), ['开会'],
        reason: '离线只读，但提醒照常本地触发');
  });
}
