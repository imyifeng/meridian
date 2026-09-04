import 'package:flutter/material.dart';

import 'app.dart';
import 'memo_cache.dart';
import 'reminders_plugin.dart';
import 'token_store.dart';

void main() {
  runApp(MeridianApp(
    // LAN addresses are expected (story: http:// 内网可用); the login screen
    // lets the user change this per device.
    baseUrl: const String.fromEnvironment('MERIDIAN_SERVER',
        defaultValue: 'http://127.0.0.1:8080'),
    tokenStore: SecureTokenStore(),
    memoCache: SecureMemoCache(),
    reminderNotifications: createReminderNotifications(),
  ));
}
