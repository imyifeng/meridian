import 'package:flutter/material.dart';

import 'app.dart';
import 'memo_cache.dart';
import 'reminders_plugin.dart';
import 'server_address_store.dart';
import 'token_store.dart';

void main() {
  runApp(MeridianApp(
    // Fallback when nothing is stored yet; LAN addresses are expected
    // (story: http:// 内网可用). The address the user logs in with
    // persists to secure storage and wins on the next launch (T11).
    baseUrl: const String.fromEnvironment('MERIDIAN_SERVER',
        defaultValue: 'http://127.0.0.1:8080'),
    tokenStore: SecureTokenStore(),
    memoCache: SecureMemoCache(),
    addressStore: SecureServerAddressStore(),
    reminderNotifications: createReminderNotifications(),
  ));
}
