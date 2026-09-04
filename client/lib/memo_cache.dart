import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

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
        'memos': [
          for (final m in memos)
            {
              'id': m.id,
              'title': m.title,
              'body': m.body,
              'category_id': m.categoryId,
              'tags': m.tags,
            },
        ],
        'categories': [
          for (final c in categories)
            {'id': c.id, 'name': c.name, 'is_builtin': c.isBuiltin},
        ],
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

/// Where the offline snapshot lives between runs. Not secrets — memo text —
/// so plain app storage is enough; a corrupt blob reads as no cache rather
/// than crashing the app.
abstract class MemoCache {
  Future<CachedSnapshot?> read();
  Future<void> write(CachedSnapshot snapshot);
  Future<void> clear();
}

class SharedPrefsMemoCache implements MemoCache {
  static const _key = 'meridian_offline_snapshot';

  @override
  Future<CachedSnapshot?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    try {
      return CachedSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(CachedSnapshot snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(snapshot.toJson()));
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
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
