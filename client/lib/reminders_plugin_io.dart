import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'api_client.dart';
import 'reminders.dart';

/// The real notification surface behind ReminderNotifications (T9): Windows
/// toast and Android notification via flutter_local_notifications. The
/// popups themselves are a manual verification item (spec); this adapter's
/// job is routing the memo title out and the tap payload back in.
class PluginReminderNotifications implements ReminderNotifications {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// The tap callback the plugin invokes; static because the plugin takes a
  /// top-level/static closure at initialize, and there is exactly one
  /// notification surface per process.
  static void Function(int memoId)? _onTap;

  @override
  Future<void> init({required void Function(int memoId) onTap}) async {
    _onTap = onTap;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      windows: WindowsInitializationSettings(
        appName: 'Meridian',
        appUserModelId: 'imyifeng.Meridian.Client',
        guid: '9d3e8a54-6c1b-4f7a-9d2e-8b5c7a1f0e34',
      ),
    );
    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onResponse,
    );
    // Android 13+ gates notifications behind a runtime ask; other platforms
    // have nothing to ask.
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  static void _onResponse(NotificationResponse response) {
    final id = int.tryParse(response.payload ?? '');
    if (id != null) _onTap?.call(id);
  }

  @override
  Future<void> showDueReminder(Memo memo) {
    // The notification id is the memo id, so a re-shown memo replaces its
    // own notice instead of piling up.
    return _plugin.show(
      id: memo.id,
      title: memo.title,
      body: '提醒时间到（${formatReminder(memo.remindAt!)}），点按查看',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'reminders',
          '备忘录提醒',
          importance: Importance.max,
          priority: Priority.high,
        ),
        windows: WindowsNotificationDetails(),
      ),
      payload: '${memo.id}',
    );
  }
}

ReminderNotifications createReminderNotifications() =>
    PluginReminderNotifications();
