import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the client keeps its long-lived credential between runs: platform
/// secure storage in production (Windows 凭据管理 / Android Keystore 体系),
/// in-memory wherever the session is the lifetime — widget tests, and the
/// Web 简易客户端, whose credential dies with the browser tab (T10).
abstract class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

class SecureTokenStore implements TokenStore {
  static const _key = 'meridian_token';
  final FlutterSecureStorage _storage;

  SecureTokenStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class InMemoryTokenStore implements TokenStore {
  String? _token;

  @override
  Future<String?> read() async => _token;

  @override
  Future<void> write(String token) async => _token = token;

  @override
  Future<void> clear() async => _token = null;
}
