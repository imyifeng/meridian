import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// In-process fake of the Meridian HTTP API, same shape as the real Go
/// server: /api/v1/instance, /api/v1/setup/admin, /api/v1/auth/login,
/// /api/v1/memos. UI seam tests drive the real widget tree with the app's
/// real HTTP layer (request building, JSON, status handling) pointed at
/// this fake via an injected http.Client — widget tests cannot open real
/// sockets, but they can run this in-process handler.
class FakeMeridianServer {
  FakeMeridianServer({this.initialized = false});

  bool initialized;
  final Map<String, String> _passwords = {}; // username -> password
  final Map<String, String> _tokens = {}; // token -> username
  final List<Map<String, dynamic>> _memos = [];
  int _nextUserId = 1;
  int _nextMemoId = 1;

  /// Base URL for the app under test; host and port are meaningless —
  /// routing is by path only.
  final String url = 'http://fake.meridian.local';

  /// An http.Client that serves this fake instance.
  http.Client get client => MockClient(_route);

  /// Pre-seeds an account, standing in for the setup wizard.
  void registerUser(String username, String password) {
    _passwords[username] = password;
    initialized = true;
  }

  Future<http.Response> _route(http.Request request) async {
    final path = request.url.path;
    final segments = path.split('/');
    final memoId = segments.length == 5 && segments[3] == 'memos'
        ? int.tryParse(segments[4])
        : null;

    http.Response r;
    if (path == '/api/v1/instance' && request.method == 'GET') {
      r = _json(200, {'initialized': initialized});
    } else if (path == '/api/v1/setup/admin' && request.method == 'POST') {
      r = await _setup(request);
    } else if (path == '/api/v1/auth/login' && request.method == 'POST') {
      r = await _login(request);
    } else if (memoId != null && request.method == 'GET') {
      r = await _withAuth(request, (user) async {
        final match = _memos.where((m) => m['id'] == memoId && m['user_id'] == user).toList();
        return match.isEmpty ? _json(404, {'error': 'not_found'}) : _json(200, match.first);
      });
    } else if (path == '/api/v1/memos' && request.method == 'GET') {
      r = await _withAuth(request, (user) async => _json(200, {
            'memos': _memos.where((m) => m['user_id'] == user).toList(),
          }));
    } else if (path == '/api/v1/memos' && request.method == 'POST') {
      r = await _withAuth(request, (user) => _createMemo(request, user));
    } else if (memoId != null && request.method == 'PUT') {
      r = await _withAuth(request, (user) => _updateMemo(request, user, memoId));
    } else if (memoId != null && request.method == 'DELETE') {
      r = await _withAuth(request, (user) async => _deleteMemo(user, memoId));
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
      'user': {'id': _nextUserId++, 'username': username, 'role': 'administrator'},
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
      'user': {'id': _nextUserId, 'username': username, 'role': 'administrator'},
    });
  }

  Future<http.Response> _createMemo(http.Request request, String user) async {
    final body = _body(request);
    final title = (body['title'] as String? ?? '').trim();
    if (title.isEmpty) return _json(400, {'error': 'invalid_request'});
    final now = DateTime.now().toUtc().toIso8601String();
    final memo = {
      'id': _nextMemoId++,
      'user_id': user,
      'title': title,
      'body': body['body'] as String? ?? '',
      'created_at': now,
      'updated_at': now,
    };
    _memos.add(memo);
    return _json(201, memo);
  }

  Future<http.Response> _updateMemo(http.Request request, String user, int id) async {
    final idx = _memos.indexWhere((m) => m['id'] == id && m['user_id'] == user);
    if (idx == -1) return _json(404, {'error': 'not_found'});
    final body = _body(request);
    final title = (body['title'] as String? ?? '').trim();
    if (title.isEmpty) return _json(400, {'error': 'invalid_request'});
    _memos[idx]['title'] = title;
    _memos[idx]['body'] = body['body'] as String? ?? '';
    _memos[idx]['updated_at'] = DateTime.now().toUtc().toIso8601String();
    return _json(200, _memos[idx]);
  }

  http.Response _deleteMemo(String user, int id) {
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
