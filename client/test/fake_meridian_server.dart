import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// In-process fake of the Meridian HTTP API, same shape as the real Go
/// server: /api/v1/instance, /api/v1/setup/administrator, /api/v1/auth/login,
/// /api/v1/categories, /api/v1/memos, /api/v1/users. UI seam tests drive the
/// real widget tree with the app's real HTTP layer (request building, JSON,
/// status handling) pointed at this fake via an injected http.Client — widget
/// tests cannot open real sockets, but they can run this in-process handler.
class FakeMeridianServer {
  FakeMeridianServer() {
    // Same as the real instance: the built-in 未分类 always exists (ADR-0002).
    final builtin = {'id': 1, 'name': '未分类', 'is_builtin': true};
    _categories[builtin['id'] as int] = builtin;
    _nextCategoryId = 2;
  }

  bool initialized = false;
  final Map<String, Map<String, dynamic>> _users =
      {}; // username -> {id, username, role}
  final Map<String, String> _passwords = {}; // username -> password
  final Map<String, String> _tokens = {}; // token -> username
  final Map<int, Map<String, dynamic>> _categories = {}; // id -> category
  final List<Map<String, dynamic>> _memos = [];
  int _nextCategoryId = 1;
  int _nextUserId = 1;
  int _nextMemoId = 1;

  /// Base URL for the app under test; host and port are meaningless —
  /// routing is by path only.
  final String url = 'http://fake.meridian.local';

  /// An http.Client that serves this fake instance.
  http.Client get client => MockClient(_route);

  /// Pre-seeds a user, standing in for the setup wizard.
  void registerUser(String username, String password,
      {String role = 'administrator'}) {
    _passwords[username] = password;
    _users[username] = {'id': _nextUserId++, 'username': username, 'role': role};
    initialized = true;
  }

  /// Pre-seeds an ordinary user, standing in for console user management.
  Map<String, dynamic> createUser(String username, String password) {
    _passwords[username] = password;
    final user = {'id': _nextUserId++, 'username': username, 'role': 'user'};
    _users[username] = user;
    return user;
  }

  /// Pre-seeds a memo owned by [username], standing in for that user's client.
  void seedMemo(String username, String title) {
    _memos.add({
      'id': _nextMemoId++,
      'user_id': username,
      'category_id': uncategorizedId,
      'title': title,
      'body': '',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Map<String, dynamic> userByName(String username) => _users[username]!;

  /// Pre-seeds a category, standing in for console management.
  Map<String, dynamic> createCategory(String name) {
    final category = {
      'id': _nextCategoryId++,
      'name': name,
      'is_builtin': false,
    };
    _categories[category['id'] as int] = category;
    return category;
  }

  int get uncategorizedId =>
      _categories.values.firstWhere((c) => c['is_builtin'] == true)['id'] as int;

  Future<http.Response> _route(http.Request request) async {
    final path = request.url.path;
    final segments = path.split('/');
    final resource = segments.length == 5 &&
            (segments[3] == 'memos' ||
                segments[3] == 'categories' ||
                segments[3] == 'users')
        ? segments[3]
        : null;
    final resourceId = resource != null ? int.tryParse(segments[4]) : null;

    http.Response r;
    if (path == '/api/v1/instance' && request.method == 'GET') {
      r = _json(200, {'initialized': initialized});
    } else if (path == '/api/v1/setup/administrator' && request.method == 'POST') {
      r = await _setup(request);
    } else if (path == '/api/v1/auth/login' && request.method == 'POST') {
      r = await _login(request);
    } else if (path == '/api/v1/categories' && request.method == 'GET') {
      r = await _withAuth(request, (_) async => _json(200, {
            'categories': _categories.values.toList(),
          }));
    } else if (path == '/api/v1/categories' && request.method == 'POST') {
      r = await _withAuth(request, (user) async => _createCategory(request, user));
    } else if (resource == 'categories' && request.method == 'DELETE') {
      r = await _withAuth(request, (user) async => _deleteCategory(user, resourceId));
    } else if (resource == 'memos' && request.method == 'GET') {
      r = await _withAuth(request, (user) async {
        final match = _memos.where((m) => m['id'] == resourceId && m['user_id'] == user).toList();
        return match.isEmpty ? _json(404, {'error': 'not_found'}) : _json(200, match.first);
      });
    } else if (path == '/api/v1/memos' && request.method == 'GET') {
      r = await _withAuth(request, (user) async => _json(200, {
            'memos': _memos.where((m) => m['user_id'] == user).toList(),
          }));
    } else if (path == '/api/v1/memos' && request.method == 'POST') {
      r = await _withAuth(request, (user) => _createMemo(request, user));
    } else if (resource == 'memos' && request.method == 'PUT') {
      r = await _withAuth(request, (user) => _updateMemo(request, user, resourceId));
    } else if (resource == 'memos' && request.method == 'DELETE') {
      r = await _withAuth(request, (user) async => _deleteMemo(user, resourceId));
    } else if (path == '/api/v1/users' && request.method == 'GET') {
      r = await _withAuth(request, (user) async => _listUsers(user));
    } else if (path == '/api/v1/users' && request.method == 'POST') {
      r = await _withAuth(request, (user) async => _createUser(request, user));
    } else if (segments.length == 6 &&
        segments[3] == 'users' &&
        segments[5] == 'password' &&
        request.method == 'PUT') {
      r = await _withAuth(request, (user) async => _resetPassword(user, int.tryParse(segments[4]), request));
    } else if (resource == 'users' && request.method == 'DELETE') {
      r = await _withAuth(request, (user) async => _deleteUser(user, resourceId));
    } else {
      r = _json(404, {'error': 'not_found'});
    }
    return r;
  }

  Future<http.Response> _setup(http.Request request) async {
    final body = _body(request);
    final username = body['username'] as String? ?? '';
    final password = body['password'] as String? ?? '';
    if (username.trim().isEmpty || password.isEmpty) {
      return _json(400, {'error': 'invalid_request'});
    }
    if (initialized) return _json(409, {'error': 'already_initialized'});
    registerUser(username, password);
    final token = _newToken(username);
    return _json(201, {
      'token': token,
      'user': _users[username],
    });
  }

  Future<http.Response> _login(http.Request request) async {
    final body = _body(request);
    final username = body['username'] as String? ?? '';
    final password = body['password'] as String? ?? '';
    if (_passwords[username] != password) {
      return _json(401, {'error': 'invalid_credentials'});
    }
    return _json(200, {
      'token': _newToken(username),
      'user': _users[username],
    });
  }

  http.Response _listUsers(String user) {
    if (!_isAdministrator(user)) return _json(403, {'error': 'administrator_only'});
    final users = [
      for (final u in _users.values)
        {
          ...u,
          'memo_count': _memos.where((m) => m['user_id'] == u['username']).length,
        },
    ];
    return _json(200, {'users': users});
  }

  http.Response _createUser(http.Request request, String user) {
    if (!_isAdministrator(user)) return _json(403, {'error': 'administrator_only'});
    final body = _body(request);
    // Same as the real store: the name is trimmed before the uniqueness
    // check, so whitespace variants collide with existing users.
    final username = (body['username'] as String? ?? '').trim();
    final password = body['password'] as String? ?? '';
    if (username.isEmpty || password.trim().isEmpty) {
      return _json(400, {'error': 'invalid_request'});
    }
    if (_users.containsKey(username)) {
      return _json(409, {'error': 'username_taken'});
    }
    final created = createUser(username, password);
    return _json(201, created);
  }

  http.Response _resetPassword(String user, int? id, http.Request request) {
    if (!_isAdministrator(user)) return _json(403, {'error': 'administrator_only'});
    final target = _usernameById(id);
    if (target == null) return _json(404, {'error': 'not_found'});
    final password = _body(request)['password'] as String? ?? '';
    if (password.trim().isEmpty) return _json(400, {'error': 'invalid_request'});
    _passwords[target] = password;
    // Same as the real server: a reset ends sessions issued under the old
    // password.
    _tokens.removeWhere((_, name) => name == target);
    return http.Response('', 204);
  }

  http.Response _deleteUser(String user, int? id) {
    if (!_isAdministrator(user)) return _json(403, {'error': 'administrator_only'});
    final target = _usernameById(id);
    if (target == null) return _json(404, {'error': 'not_found'});
    if (target == user) return _json(409, {'error': 'self_delete'});
    // Cascade: the user, their memos, and their sessions all disappear.
    _users.remove(target);
    _passwords.remove(target);
    _memos.removeWhere((m) => m['user_id'] == target);
    _tokens.removeWhere((_, name) => name == target);
    return http.Response('', 204);
  }

  String? _usernameById(int? id) {
    for (final u in _users.values) {
      if (u['id'] == id) return u['username'] as String;
    }
    return null;
  }

  http.Response _createCategory(http.Request request, String user) {
    if (!_isAdministrator(user)) return _json(403, {'error': 'administrator_only'});
    final body = _body(request);
    final name = (body['name'] as String? ?? '').trim();
    if (name.isEmpty) return _json(400, {'error': 'invalid_request'});
    if (_categories.values.any((c) => c['name'] == name)) {
      return _json(409, {'error': 'name_taken'});
    }
    final category = {
      'id': _nextCategoryId++,
      'name': name,
      'is_builtin': false,
    };
    _categories[category['id'] as int] = category;
    return _json(201, category);
  }

  http.Response _deleteCategory(String user, int? id) {
    if (!_isAdministrator(user)) return _json(403, {'error': 'administrator_only'});
    final category = _categories[id];
    if (category == null) return _json(404, {'error': 'not_found'});
    if (category['is_builtin'] == true) {
      return _json(409, {'error': 'builtin_category'});
    }
    // Same as the real server: the category's memos fall back to 未分类.
    for (final memo in _memos) {
      if (memo['category_id'] == id) memo['category_id'] = uncategorizedId;
    }
    _categories.remove(id);
    return http.Response('', 204);
  }

  bool _isAdministrator(String user) =>
      _users[user]?['role'] == 'administrator';

  /// Category assignment mirrors the real server: omitted → 未分类 (create)
  /// or unchanged (update); present but unknown → 400.
  int _resolveCategoryId(Map<String, dynamic> body, {int? current}) {
    final requested = body['category_id'] as int?;
    if (requested == null) return current ?? uncategorizedId;
    if (!_categories.containsKey(requested)) return -1;
    return requested;
  }

  Future<http.Response> _createMemo(http.Request request, String user) async {
    final body = _body(request);
    final title = (body['title'] as String? ?? '').trim();
    if (title.isEmpty) return _json(400, {'error': 'invalid_request'});
    final categoryId = _resolveCategoryId(body);
    if (categoryId == -1) return _json(400, {'error': 'unknown_category'});
    final now = DateTime.now().toUtc().toIso8601String();
    final memo = {
      'id': _nextMemoId++,
      'user_id': user,
      'category_id': categoryId,
      'title': title,
      'body': body['body'] as String? ?? '',
      'created_at': now,
      'updated_at': now,
    };
    _memos.add(memo);
    return _json(201, memo);
  }

  Future<http.Response> _updateMemo(http.Request request, String user, int? id) async {
    final idx = _memos.indexWhere((m) => m['id'] == id && m['user_id'] == user);
    if (idx == -1) return _json(404, {'error': 'not_found'});
    final body = _body(request);
    final title = (body['title'] as String? ?? '').trim();
    if (title.isEmpty) return _json(400, {'error': 'invalid_request'});
    final categoryId =
        _resolveCategoryId(body, current: _memos[idx]['category_id'] as int);
    if (categoryId == -1) return _json(400, {'error': 'unknown_category'});
    _memos[idx]['title'] = title;
    _memos[idx]['body'] = body['body'] as String? ?? '';
    _memos[idx]['category_id'] = categoryId;
    _memos[idx]['updated_at'] = DateTime.now().toUtc().toIso8601String();
    return _json(200, _memos[idx]);
  }

  http.Response _deleteMemo(String user, int? id) {
    final idx = _memos.indexWhere((m) => m['id'] == id && m['user_id'] == user);
    if (idx == -1) return _json(404, {'error': 'not_found'});
    _memos.removeAt(idx);
    return http.Response('', 204);
  }

  Future<http.Response> _withAuth(
      http.Request request, Future<http.Response> Function(String) action) async {
    final auth = request.headers['Authorization'] ?? '';
    if (!auth.startsWith('Bearer ')) return _json(401, {'error': 'unauthorized'});
    final user = _tokens[auth.substring(7)];
    if (user == null) return _json(401, {'error': 'unauthorized'});
    return action(user);
  }

  String _newToken(String username) {
    final token = 'fake-token-$username-${_tokens.length + 1}';
    _tokens[token] = username;
    return token;
  }

  Map<String, dynamic> _body(http.Request request) {
    if (request.body.isEmpty) return {};
    return jsonDecode(request.body) as Map<String, dynamic>;
  }

  http.Response _json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {
        'content-type': 'application/json; charset=utf-8',
      });
}
