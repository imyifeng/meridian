import 'package:flutter/material.dart';

import 'console/console_app.dart';

/// Entrypoint for the Web 管理控制台 (ADR-0005): built as its own Flutter Web
/// target and hosted by the meridian server at /console/. The console talks
/// to the same origin, so the API base is empty.
void main() {
  runApp(const ConsoleApp());
}
