import 'api_client.dart';
import 'reminders.dart';

/// Web stand-in for the plugin adapter: the Web 简易客户端 provides no
/// reminder notifications by design (spec story 34), so the surface is a
/// quiet no-op that never asks and never shows.
class _NoopReminderNotifications implements ReminderNotifications {
  @override
  Future<void> init({required void Function(int memoId) onTap}) async {}

  @override
  Future<void> showDueReminder(Memo memo) async {}
}

ReminderNotifications createReminderNotifications() =>
    _NoopReminderNotifications();
