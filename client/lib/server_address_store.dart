import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the client keeps the server address the user typed at login (T11):
/// the next launch brings it back instead of resetting to the compile-time
/// default. Platform secure storage in production (Windows 凭据管理 /
/// Android Keystore 体系); in-memory wherever the session is the lifetime —
/// widget tests, and the Web 简易客户端, which is same-origin and never
/// shows the field.
abstract class ServerAddressStore {
  Future<String?> read();
  Future<void> write(String address);
  Future<void> clear();
}

class SecureServerAddressStore implements ServerAddressStore {
  static const _key = 'meridian_server_address';
  final FlutterSecureStorage _storage;

  SecureServerAddressStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String address) =>
      _storage.write(key: _key, value: address);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class InMemoryServerAddressStore implements ServerAddressStore {
  String? _address;

  @override
  Future<String?> read() async => _address;

  @override
  Future<void> write(String address) async => _address = address;

  @override
  Future<void> clear() async => _address = null;
}
