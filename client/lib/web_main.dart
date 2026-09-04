import 'package:flutter/material.dart';

import 'app.dart';
import 'token_store.dart';

/// Entrypoint for the Web 简易客户端 (T10): built as its own Flutter Web
/// target and hosted by the meridian server at /web/. It shares the memo
/// screens with the Windows/Android client, but is same-origin (the server
/// is whatever served this page), lives for the browser session only
/// (in-memory stores), and carries no reminders — those fire in the
/// 客户端, and the web offers no reminder entry points either.
void main() {
  runApp(MeridianApp(
    baseUrl: '',
    tokenStore: InMemoryTokenStore(),
    webClient: true,
  ));
}
