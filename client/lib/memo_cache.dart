import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';

/// What the client keeps between runs for offline reading (ADR-0003): the
/// last full memo list the server sent for this credential, plus the
/// taxonomy names the list rows display. Keyed by the token it belongs to,
/// so a snapshot from another account is never shown.
class CachedSnapshot {
  final String token;
  final List<Memo> memos;
  final List<Category> categories;

  CachedSnapshot({
    required this.token,
    required this.memos,
    required this.categories,
  });

  Map<String, dynamic> toJson() => {
        'token': token,
        'memos': [for (final m in memos) m.toJson()],
        'categories': [for (final c in categories) c.toJson()],
      };

  factory CachedSnapshot.fromJson(Map<String, dynamic> json) =>
      CachedSnapshot(
        token: json['token'] as String,
        memos: [
          for (final m in json['memos'] as List? ?? [])
            Memo.fromJson(m as Map<String, dynamic>),
        ],
        categories: [
          for (final c in json['categories'] as List? ?? [])
            Category.fromJson(c as Map<String, dynamic>),
        ],
      );
}

/// Where the offline snapshot lives between runs. The snapshot is the
/// user's own memo text plus the credential it is bound to — personal data,
/// so it goes next to the token in platform secure storage (Windows 凭据
/// 管理 / Android Keystore 体系), not plain app storage. A corrupt blob
/// reads as no cache rather than crashing the app.
abstract class MemoCache {
  Future<CachedSnapshot?> read();
  Future<void> write(CachedSnapshot snapshot);
  Future<void> clear();
}

class SecureMemoCache implements MemoCache {
  static const _key = 'meridian_offline_snapshot';
  final FlutterSecureStorage _storage;

  SecureMemoCache([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<CachedSnapshot?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      return CachedSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(CachedSnapshot snapshot) =>
      _storage.write(key: _key, value: jsonEncode(snapshot.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class InMemoryMemoCache implements MemoCache {
  CachedSnapshot? _snapshot;

  @override
  Future<CachedSnapshot?> read() async => _snapshot;

  @override
  Future<void> write(CachedSnapshot snapshot) async => _snapshot = snapshot;

  @override
  Future<void> clear() async => _snapshot = null;
}
