import 'package:flutter/material.dart';

import 'app.dart';
import 'confirmed_draft_store.dart';
import 'identity_store.dart';
import 'memo_cache.dart';
import 'reminders_plugin.dart';
import 'server_address_store.dart';
import 'theme_mode_store.dart';
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
    identityStore: SecureIdentityStore(),
    // The theme three-state switch lives on the 我的 page (ADR-0010); only
    // the Windows/Android 客户端 gets a store, so only here is the
    // preference settable and persistent.
    themeModeStore: SecureThemeModeStore(),
    // Which draft cards this device already confirmed (#76 review): a
    // restored conversation must not offer a second confirmation.
    confirmedDraftStore: SecureConfirmedDraftStore(),
    reminderNotifications: createReminderNotifications(),
  ));
}
