import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/api_client.dart';
import 'package:meridian/app.dart';
import 'package:meridian/memo_cache.dart';
import 'package:meridian/recurrence.dart';
import 'package:meridian/reminders.dart';
import 'package:meridian/screens/memo_view_screen.dart';
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

  // Drives the real date and time pickers: [day] in the month the picker
  // is showing, at [hour]:[minute]. Finders stay scoped to the dialogs —
  // the editor underneath has TextFields of its own.
  Future<void> drivePickers(WidgetTester tester,
      {required String day, required String hour, required String minute}) async {
    await tester.tap(find.descendant(
      of: find.byType(CalendarDatePicker),
      matching: find.text(day),
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
      {required String day, String hour = '08', String minute = '30'}) async {
    await tester.tap(find.byKey(const Key('set_reminder_button')));
    await tester.pumpAndSettle();
    await drivePickers(tester, day: day, hour: hour, minute: minute);
  }

  // The fixed clock the editor tests inject (the editor judges the picked
  // reminder against it) and the reminder it makes pickable: the picker
  // always shows January 2026, so these assertions hold at any hour of any
  // day — 08:30 on the real wall clock made them fail every afternoon.
  final editorNow = DateTime(2026, 1, 1, 10);
  final pickedReminder = '2026-01-15 08:30';

  String? valueText(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('reminder_value'))).data;

  testWidgets('设置提醒：保存后可见，重开编辑器同一提醒', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    await loginAsYifeng(tester, fake, now: () => editorNow);

    await tester.tap(find.byKey(const Key('new_memo_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('title_field')), '交房租');
    await pickReminder(tester, day: '15');
    expect(valueText(tester), pickedReminder);
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    // The reminder went to the server as part of the memo.
    expect(fake.remindAtOf('交房租'), isNotNull);

    // Reopening shows the same reminder — it lives on the memo.
    await tester.tap(find.text('交房租'));
    await tester.pumpAndSettle();
    expect(valueText(tester), pickedReminder);
  });

  testWidgets('修改与取消提醒：保存后服务器上是新状态', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    await loginAsYifeng(tester, fake, now: () => editorNow);

    await tester.tap(find.byKey(const Key('new_memo_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('title_field')), '交房租');
    await pickReminder(tester, day: '15');
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('交房租'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('change_reminder_button')));
    await tester.pumpAndSettle();
    await drivePickers(tester, day: '15', hour: '09', minute: '45');
    expect(valueText(tester), '2026-01-15 09:45');
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

  testWidgets('可设置一年以后的提醒：保存、修改与取消都不受人为上限', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    await loginAsYifeng(tester, fake, now: () => editorNow);

    await tester.tap(find.byKey(const Key('new_memo_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('title_field')), '续租');

    // The spec puts no horizon on a reminder, so a date past a year out must
    // stay reachable: the month-year header of the picker (January 2026 —
    // the grid opens on editorNow's month) toggles to the year grid, picking
    // 2027 lands back on January of that year.
    await tester.tap(find.byKey(const Key('set_reminder_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('January 2026'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(DatePickerDialog),
      matching: find.text('2027'),
    ));
    await tester.pumpAndSettle();
    await drivePickers(tester, day: '15', hour: '08', minute: '30');
    expect(valueText(tester), '2027-01-15 08:30');
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();
    final saved = fake.remindAtOf('续租');
    expect(saved!.year, 2027);
    expect(saved.month, 1);
    expect(saved.day, 15);

    // Story 17 keeps holding for far reminders: change and cancel work the
    // same. The change picker reopens on the stored far date.
    await tester.tap(find.text('续租'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('change_reminder_button')));
    await tester.pumpAndSettle();
    await drivePickers(tester, day: '15', hour: '09', minute: '45');
    expect(valueText(tester), '2027-01-15 09:45');
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();
    final changed = fake.remindAtOf('续租')!;
    expect(changed.hour, 9);
    expect(changed.minute, 45);

    await tester.tap(find.text('续租'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('clear_reminder_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();
    expect(fake.remindAtOf('续租'), isNull);
  });

  testWidgets('选择已过去的时刻被拒绝，提醒不会静默失效', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    await loginAsYifeng(tester, fake);

    await tester.tap(find.byKey(const Key('new_memo_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('title_field')), '交房租');
    // Today at 00:00 — in the past unless the test runs at midnight.
    await tester.tap(find.byKey(const Key('set_reminder_button')));
    await tester.pumpAndSettle();
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
    // 12:00 AM is today at midnight — in the past unless the test runs at
    // that exact minute. (A bare 00 hour is invalid in the 12-hour picker
    // and makes OK return null instead of a time.)
    await tester.enterText(fields.first, '12');
    await tester.enterText(fields.last, '00');
    if (find.text('AM').evaluate().isNotEmpty) {
      await tester.tap(find.text('AM'));
      await tester.pump();
    }
    await tester.tap(find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.text('OK'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('提醒时间必须晚于当前时间'), findsOneWidget);
    expect(find.byKey(const Key('reminder_value')), findsNothing);
    expect(find.byKey(const Key('set_reminder_button')), findsOneWidget);
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

  testWidgets('另一台设备设置的提醒到达运行中的客户端并触发', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    var clock = DateTime(2026, 9, 4, 12, 0, 0);
    fake.seedMemo('yifeng', '开会'); // this device has not touched it
    final notifications = await loginAsYifeng(tester, fake, now: () => clock);
    expect(notifications.shown, isEmpty);

    // Another device sets a reminder that goes due between this client's
    // list loads; the quiet poll picks it up and the notice still fires.
    fake.setMemoReminder('yifeng', '开会', clock.add(const Duration(seconds: 40)));
    clock = clock.add(const Duration(minutes: 1));
    await tester.pump(ReminderService.tickInterval * 2 + const Duration(seconds: 1));

    expect(notifications.shown.map((m) => m.title), ['开会']);
  });

  testWidgets('打开时已过期的提醒不再触发；被取消的提醒解除调度', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    var clock = DateTime(2026, 9, 4, 12, 0, 0);
    // Already past when this client first sees it: old news, no pop.
    fake.seedMemo('yifeng', '旧提醒', remindAt: clock.subtract(const Duration(hours: 3)));
    // A future reminder that is then cancelled from (another device's) edit
    // never fires.
    fake.seedMemo('yifeng', '开会', remindAt: clock.add(const Duration(seconds: 30)));
    final notifications = await loginAsYifeng(tester, fake, now: () => clock);
    await tester.pump(const Duration(seconds: 16));
    expect(notifications.shown, isEmpty);

    // Opening a memo and coming back reloads the full list — an unfiltered
    // load is what feeds the scheduler.
    Future<void> reloadViaEditor() async {
      await tester.tap(find.text('开会'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
    }

    await reloadViaEditor();
    fake.setMemoReminder('yifeng', '开会', null);
    // Reload again so the cleared reminder reaches the scheduler.
    await reloadViaEditor();

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

  testWidgets('循环提醒到期触发后自动调度下一次并回写服务器', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    var clock = DateTime(2026, 9, 4, 12, 0, 0);
    // 每天 12:01：第一个触发点在登录后 1 分钟。
    const daily = {
      'mode': 'daily',
      'interval': 1,
      'hour': 12,
      'minute': 1,
    };
    fake.seedMemo('yifeng', '喝水',
        remindAt: DateTime(2026, 9, 4, 12, 1), remindRule: daily);
    final notifications = await loginAsYifeng(tester, fake, now: () => clock);
    expect(notifications.shown, isEmpty, reason: '未到期不应通知');

    // 越过第一个触发点：弹一次通知，客户端把下一次回写。
    clock = clock.add(const Duration(minutes: 2));
    await tester.pump(const Duration(seconds: 16));
    expect(notifications.shown.map((m) => m.title), ['喝水']);
    await tester.pump(const Duration(milliseconds: 100)); // 回写落盘
    expect(fake.remindAtOf('喝水'), DateTime(2026, 9, 5, 12, 1),
        reason: '触发后应回写下一次触发时间点');
    expect(fake.remindRuleOf('喝水'), daily, reason: '回写不动循环规则');

    // 静默轮询取回回写值（与本地再武装的值一致，调度不受扰动）。
    await tester.pump(ReminderService.tickInterval * 2 + const Duration(seconds: 1));

    // 越过第二个触发点：同一条循环提醒再弹一次，再回写。
    clock = clock.add(const Duration(days: 1));
    await tester.pump(const Duration(seconds: 16));
    expect(notifications.shown.map((m) => m.title), ['喝水', '喝水']);
    await tester.pump(const Duration(milliseconds: 100));
    expect(fake.remindAtOf('喝水'), DateTime(2026, 9, 6, 12, 1));
  });

  testWidgets('错过的循环提醒不补发，推进到下一次并回写', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    // 客户端三天没开：remind_at（每天 12:01）停在 9 月 1 日，早已过宽限。
    var clock = DateTime(2026, 9, 4, 12, 5, 0);
    fake.seedMemo('yifeng', '喝水',
        remindAt: DateTime(2026, 9, 1, 12, 1),
        remindRule: const {
          'mode': 'daily',
          'interval': 1,
          'hour': 12,
          'minute': 1,
        });
    final notifications = await loginAsYifeng(tester, fake, now: () => clock);
    await tester.pump(const Duration(seconds: 16));
    expect(notifications.shown, isEmpty, reason: '错过的触发不补发');
    await tester.pump(const Duration(milliseconds: 100)); // 回写落盘
    expect(fake.remindAtOf('喝水'), DateTime(2026, 9, 5, 12, 1),
        reason: '循环应从当前时刻推进到未来的下一次，而不是无声死亡');
  });

  testWidgets('回写只移动触发点，不还原其他设备的修改', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    var clock = DateTime(2026, 9, 4, 12, 0, 0);
    fake.seedMemo('yifeng', '喝水',
        body: '本机见过的旧正文',
        remindAt: DateTime(2026, 9, 4, 12, 1),
        remindRule: const {
          'mode': 'daily',
          'interval': 1,
          'hour': 12,
          'minute': 1,
        });
    final notifications = await loginAsYifeng(tester, fake, now: () => clock);

    // 触发前，另一台设备改了正文——本机的列表快照还停在旧值。
    fake.setMemoBody('yifeng', '喝水', '另一台设备改过的新正文');

    clock = clock.add(const Duration(minutes: 2));
    await tester.pump(const Duration(seconds: 16));
    expect(notifications.shown.map((m) => m.title), ['喝水']);
    await tester.pump(const Duration(milliseconds: 100)); // 回写落盘
    expect(fake.remindAtOf('喝水'), DateTime(2026, 9, 5, 12, 1));
    expect(fake.bodyOf('喝水'), '另一台设备改过的新正文',
        reason: '回写不得用旧快照还原其他设备的修改');
  });

  testWidgets('循环被移除或备忘录被删除后不再触发', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    var clock = DateTime(2026, 9, 4, 12, 0, 0);
    fake.seedMemo('yifeng', '喝水',
        remindAt: DateTime(2026, 9, 4, 12, 1),
        remindRule: const {
          'mode': 'daily',
          'interval': 1,
          'hour': 12,
          'minute': 1,
        });
    fake.seedMemo('yifeng', '吃药',
        remindAt: DateTime(2026, 9, 4, 12, 1),
        remindRule: const {
          'mode': 'weekly',
          'interval': 1,
          'weekday': 5,
          'hour': 12,
          'minute': 1,
        });
    final notifications = await loginAsYifeng(tester, fake, now: () => clock);

    // 另一台设备移除了「喝水」的循环（时间点与规则一并清除），删除了「吃药」。
    fake.clearMemoReminder('yifeng', '喝水');
    fake.deleteMemoByTitle('yifeng', '吃药');

    // 静默轮询把两个动作都带进调度器——此时都还未到期。
    await tester.pump(
        ReminderService.tickInterval * 2 + const Duration(seconds: 1));

    clock = clock.add(const Duration(minutes: 5));
    await tester.pump(const Duration(seconds: 16));
    expect(notifications.shown, isEmpty, reason: '循环已移除或备忘录已删除，不应再触发');
  });

  // Drives the recurrence dialog to a weekly-Wednesday 08:30 rule: opens
  // it, picks the mode and weekday from the dropdowns, and sets the time
  // through the real time picker.
  Future<void> pickWeeklyReminder(WidgetTester tester,
      {required String weekday,
      required String hour,
      required String minute}) async {
    await tester.tap(find.byKey(const Key('set_recurrence_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recurrence_mode_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每周').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recurrence_weekday_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(weekday).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recurrence_time_button')));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.first, hour);
    await tester.enterText(fields.last, minute);
    if (find.text('AM').evaluate().isNotEmpty) {
      await tester.tap(find.text('AM'));
      await tester.pump();
    }
    await tester.tap(find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.text('OK'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recurrence_save_button')));
    await tester.pumpAndSettle();
  }

  testWidgets('设置循环提醒：保存后规则与下次时间点入库，重开编辑器同一循环', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    await loginAsYifeng(tester, fake, now: () => editorNow);

    await tester.tap(find.byKey(const Key('new_memo_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('title_field')), '周报');
    // editorNow 是 2026-01-01（周四）10:00：首个周三触发点是 1 月 7 日。
    await pickWeeklyReminder(tester, weekday: '周三', hour: '08', minute: '30');
    expect(valueText(tester), '每周三 08:30 · 下次 2026-01-07 08:30');
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();

    expect(fake.remindRuleOf('周报'),
        {'mode': 'weekly', 'interval': 1, 'weekday': 3, 'hour': 8, 'minute': 30});
    expect(fake.remindAtOf('周报'), DateTime(2026, 1, 7, 8, 30));

    // Reopening shows the same recurrence — it lives on the memo.
    await tester.tap(find.text('周报'));
    await tester.pumpAndSettle();
    expect(valueText(tester), '每周三 08:30 · 下次 2026-01-07 08:30');
  });

  testWidgets('修改与清除循环提醒：保存后服务器上是新状态', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '周报',
        remindAt: DateTime(2026, 1, 7, 8, 30),
        remindRule: const {
          'mode': 'weekly',
          'interval': 1,
          'weekday': 3,
          'hour': 8,
          'minute': 30,
        });
    await loginAsYifeng(tester, fake, now: () => editorNow);

    await tester.tap(find.text('周报'));
    await tester.pumpAndSettle();
    expect(valueText(tester), '每周三 08:30 · 下次 2026-01-07 08:30');

    // 修改：改为每 2 周的周三，触发点重算——首出现仍在 1 月 7 日。
    await tester.tap(find.byKey(const Key('change_reminder_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recurrence_dialog')), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('recurrence_interval_field')), '2');
    await tester.pump();
    await tester.tap(find.byKey(const Key('recurrence_save_button')));
    await tester.pumpAndSettle();
    expect(valueText(tester), '每 2 周的周三 08:30 · 下次 2026-01-07 08:30');
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();
    expect(fake.remindRuleOf('周报')?['interval'], 2);
    expect(fake.remindAtOf('周报'), DateTime(2026, 1, 7, 8, 30));

    // 清除：时间点与循环一并消失。
    await tester.tap(find.text('周报'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('clear_reminder_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reminder_value')), findsNothing);
    expect(find.byKey(const Key('set_reminder_button')), findsOneWidget);
    expect(find.byKey(const Key('set_recurrence_button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('save_button')));
    await tester.pumpAndSettle();
    expect(fake.remindAtOf('周报'), isNull);
    expect(fake.remindRuleOf('周报'), isNull);
  });

  testWidgets('查看页对循环提醒显示规则与下次触发时间点', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MemoViewScreen(
        memo: Memo(
          id: 1,
          title: '周报',
          body: '',
          categoryId: 1,
          remindAt: DateTime(2026, 1, 7, 8, 30),
          remindRule: const ReminderRule(
            mode: ReminderMode.weekly,
            weekday: 3,
            hour: 8,
            minute: 30,
          ),
        ),
      ),
    ));
    expect(find.text('提醒：每周三 08:30 · 下次 2026-01-07 08:30'), findsOneWidget);
  });
}
