// Picks the reminder notification surface per platform: the plugin adapter
// where dart:io exists (Windows client, Android client), the quiet no-op on
// web — the Web 简易客户端 carries no reminder notifications.
export 'reminders_plugin_stub.dart'
    if (dart.library.io) 'reminders_plugin_io.dart';
