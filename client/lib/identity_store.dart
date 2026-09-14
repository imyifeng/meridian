import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';

/// Where the client remembers who the stored credential belongs to, so the
/// 我的 page (#71) can name the account across restarts: the login response
/// teaches it, and sign-out drops it — the next user of this device must
/// not be shown the previous one's name. Platform secure storage in
/// production, in-memory in tests. Display data only: nothing is added to
/// the server's account data model.
abstract class IdentityStore {
  Future<User?> read();
  Future<void> write(User user);
  Future<void> clear();
}

class SecureIdentityStore implements IdentityStore {
  static const _key = 'meridian_identity';
  final FlutterSecureStorage _storage;

  SecureIdentityStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<User?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      return User.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // A garbled entry must never keep the app from signing in.
      return null;
    }
  }

  @override
  Future<void> write(User user) =>
      _storage.write(key: _key, value: jsonEncode(user.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class InMemoryIdentityStore implements IdentityStore {
  User? _user;

  @override
  Future<User?> read() async => _user;

  @override
  Future<void> write(User user) async => _user = user;

  @override
  Future<void> clear() async => _user = null;
}
