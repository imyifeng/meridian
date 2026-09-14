import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'theme.dart';

/// Where the 客户端 keeps its theme preference (ADR-0010): 深色, 浅色, or
/// 跟随系统 — the default. Client-local only, never account data: the
/// server never hears about it. Platform secure storage in production,
/// in-memory in tests; the Web 简易客户端 and the Console receive no store
/// at all and keep following the system.
abstract class ThemeModeStore {
  Future<ThemeMode> read();
  Future<void> write(ThemeMode mode);
}

class SecureThemeModeStore implements ThemeModeStore {
  static const _key = 'meridian_theme_mode';
  final FlutterSecureStorage _storage;

  SecureThemeModeStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<ThemeMode> read() async =>
      themeModeFromName(await _storage.read(key: _key));

  @override
  Future<void> write(ThemeMode mode) =>
      _storage.write(key: _key, value: mode.name);
}

class InMemoryThemeModeStore implements ThemeModeStore {
  ThemeMode _mode = ThemeMode.system;

  @override
  Future<ThemeMode> read() async => _mode;

  @override
  Future<void> write(ThemeMode mode) async => _mode = mode;
}
