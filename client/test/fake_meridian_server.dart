import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// In-process fake of the Meridian HTTP API, same shape as the real Go
/// server: /api/v1/instance, /api/v1/setup/administrator, /api/v1/auth/login,
/// /api/v1/categories, /api/v1/memos, /api/v1/trash, /api/v1/tags,
/// /api/v1/users, /api/v1/ai/settings. UI seam tests drive the
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

  /// True simulates the network being cut (T8): every request dies the way
  /// an unreachable server does, so the app sees ApiException.unreachable.
  bool offline = false;
  final Map<String, Map<String, dynamic>> _users =
      {}; // username -> {id, username, role}
  final Map<String, String> _passwords = {}; // username -> password
  final Map<String, String> _tokens = {}; // token -> username
  final Map<int, Map<String, dynamic>> _categories = {}; // id -> category
  final List<Map<String, dynamic>> _memos = [];

  /// The instance's AI 设置 (ADR-0009), one row like the real server's.
  /// api_key holds the plaintext here — the real server's trust boundary is
  /// its database, the fake's is this field; reads mask it the same way.
  Map<String, dynamic> aiSettings = {
    'base_url': '',
    'model': '',
    'api_key': '',
    'enabled': false,
  };

  /// What the next 连接测试 returns; tests set it to script failures. The
  /// real dial (key against the configured service) is pinned by the
  /// server's own seam tests, not re-enacted here.
  Map<String, dynamic> aiTestResult = {'success': true};

  /// Scripted 智能体 replies (#76): the next POST /api/v1/agent/messages in
  /// configured mode consumes the first entry and streams its frames — each
  /// a protocol frame, e.g. {'type': 'delta', 'text': '…'} — as its own
  /// chunk, so the widget under test is genuinely fed piece by piece. A
  /// frame of {'type': '_break'} ends the reply abruptly with a stream
  /// error after the frames before it — the network dying mid-reply. An
  /// empty script answers with a model-failure error frame, like the real
  /// server answers a dial it cannot complete.
  List<List<Map<String, dynamic>>> agentReplies = [];

  /// Every body the agent POST endpoint has received, in order — lets tests
  /// assert exactly what a send exported over the wire.
  final List<Map<String, dynamic>> agentRequests = [];

  /// How many times the conversation has been cleared.
  int agentClearCalls = 0;

  /// Fake-clock gap between two streamed frames; widget tests advance it
  /// with pump(duration), which is what makes incremental rendering
  /// observable mid-stream.
  Duration agentFrameDelay = const Duration(milliseconds: 50);

  final Map<String, List<Map<String, dynamic>>> _conversations = {};
  int _nextMessageId = 1;

  /// Pre-seeds a conversation's display record, standing in for turns kept
  /// from earlier sessions. Draft-carrying rows render as cards on entry.
  void seedConversation(String username, List<Map<String, dynamic>> messages) {
    _conversations[username] = [
      for (final m in messages)
        {
          'id': _nextMessageId++,
          'awaiting_input': false,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          ...m,
        },
    ];
  }

  /// The display record as the server keeps it right now.
  List<Map<String, dynamic>> conversationOf(String username) =>
      _conversations[username] ?? const [];

  /// How many times the console has asked for a connection test.
  int aiTestCalls = 0;
  int _nextCategoryId = 1;
  int _nextUserId = 1;
  int _nextMemoId = 1;

  /// Base URL for the app under test; host and port are meaningless —
  /// routing is by path only.
  final String url = 'http://fake.meridian.local';

  /// An http.Client that serves this fake instance. Streaming, because the
  /// agent endpoint (#76) hands the app its reply frame by frame — the SSE
  /// producer below paces the chunks — while every other endpoint is
  /// answered whole through the same handler.
  http.Client get client => MockClient.streaming(_routeStreaming);

  Future<http.StreamedResponse> _routeStreaming(
      http.BaseRequest base, http.ByteStream bodyStream) async {
    if (offline) throw const SocketException('offline');
    final Uint8List bytes = await bodyStream.toBytes();
    if (base.url.path == '/api/v1/agent/messages' && base.method == 'POST') {
      return _agentPost(base, bytes);
    }
    // Everything else routes through the plain handler unchanged.
    final request = http.Request(base.method, base.url)
      ..followRedirects = base.followRedirects
      ..headers.addAll(base.headers);
    if (bytes.isNotEmpty) request.bodyBytes = bytes;
    final response = await _route(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      contentLength: response.bodyBytes.length,
      reasonPhrase: response.reasonPhrase,
    );
  }

  /// The agent's send endpoint (#74): body validation (400) before any SSE,
  /// the availability gate as an error frame inside a 200 stream, then the
  /// scripted reply. The display record moves the way the real server's
  /// does: the user's turn is kept before the reply work starts, the
  /// assistant's — what streamed, nothing more — when the done frame goes
  /// out; a gate rejection keeps nothing.
  Future<http.StreamedResponse> _agentPost(
      http.BaseRequest base, List<int> bytes) async {
    final auth = base.headers['Authorization'] ?? '';
    final user =
        _tokens[auth.startsWith('Bearer ') ? auth.substring(7) : ''];
    if (user == null) return _streamedJson(401, {'error': 'unauthorized'});
    final body =
        bytes.isEmpty ? <String, dynamic>{} : jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    agentRequests.add(Map<String, dynamic>.from(body));
    final content = (body['content'] as String? ?? '').trim();
    final localTime = body['local_time'] as String? ?? '';
    final timezone = body['timezone'] as String? ?? '';
    // Same three gates as the real handler: content present, local_time an
    // RFC3339 stamp with an offset, timezone a sane single line.
    if (content.isEmpty ||
        !_strictRfc3339.hasMatch(localTime) ||
        DateTime.tryParse(localTime) == null ||
        timezone.isEmpty ||
        timezone.length > 64 ||
        timezone.contains(RegExp('[\x00-\x1f\x7f]'))) {
      return _streamedJson(400, {'error': 'invalid_request'});
    }
    final configured = (aiSettings['base_url'] as String? ?? '').isNotEmpty &&
        (aiSettings['model'] as String? ?? '').isNotEmpty &&
        (aiSettings['api_key'] as String? ?? '').isNotEmpty;
    final List<Map<String, dynamic>> frames;
    if (!configured) {
      frames = [
        {
          'type': 'error',
          'code': 'not_configured',
          'message': '智能体尚未配置，请联系管理员在 Web Console 中完成 AI 设置',
        },
      ];
    } else if (aiSettings['enabled'] != true) {
      frames = [
        {
          'type': 'error',
          'code': 'disabled',
          'message': '智能体已停用，请联系管理员在 Web Console 中开启 AI 设置',
        },
      ];
    } else {
      _conversations
          .putIfAbsent(user, () => [])
          .add({
            'id': _nextMessageId++,
            'role': 'user',
            'content': content,
            'awaiting_input': false,
            'created_at': DateTime.now().toUtc().toIso8601String(),
          });
      frames = agentReplies.isNotEmpty
          ? agentReplies.removeAt(0)
          : [
              {
                'type': 'error',
                'code': 'internal',
                'message': '回复生成失败，请稍后重试或联系管理员检查 AI 设置',
              },
            ];
    }
    return _agentSse(user, frames);
  }

  /// Streams [frames] as `data: {…}\n\n` chunks, one delayed beat apart, and
  /// keeps the assistant's display row the moment the done frame goes out.
  http.StreamedResponse _agentSse(
      String user, List<Map<String, dynamic>> frames) {
    final controller = StreamController<List<int>>();
    Future<void>(() async {
      for (final frame in frames) {
        await Future<void>.delayed(agentFrameDelay);
        if (frame['type'] == '_break') {
          // The scripted network death: an error down the stream, then
          // silence — exactly what a dropped connection looks like.
          controller.addError(const SocketException('stream broken'));
          break;
        }
        if (frame['type'] == 'done') {
          final text = [
            for (final f in frames.takeWhile((f) => f['type'] != 'done'))
              if (f['type'] == 'delta') f['text'] as String,
          ].join();
          final drafts = [
            for (final f in frames)
              if (f['type'] == 'draft') f['draft'],
          ];
          _conversations.putIfAbsent(user, () => []).add({
            'id': _nextMessageId++,
            'role': 'assistant',
            'content': text,
            'awaiting_input': frame['awaiting_input'] ?? true,
            'created_at': DateTime.now().toUtc().toIso8601String(),
            if (drafts.isNotEmpty) 'draft': drafts.last,
          });
        }
        controller.add(utf8.encode('data: ${jsonEncode(frame)}\n\n'));
      }
      await controller.close();
    });
    return http.StreamedResponse(
      controller.stream,
      200,
      headers: {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache',
      },
    );
  }

  http.StreamedResponse _streamedJson(int status, Object body) =>
      http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  /// The exacting half of local_time validation: RFC3339 demands an offset,
  /// which DateTime.tryParse alone does not — this is what pins the client's
  /// rfc3339Local output shape.
  static final RegExp _strictRfc3339 =
      RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$');

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
  void seedMemo(String username, String title,
      {String? body, List<String>? tags, int? categoryId, DateTime? remindAt,
      Map<String, dynamic>? remindRule}) {
    _memos.add({
      'id': _nextMemoId++,
      'user_id': username,
      'category_id': categoryId ?? uncategorizedId,
      'title': title,
      'body': body ?? '',
      'tags': tags != null ? _normalizeTags(tags)! : <String>[],
      'remind_at': remindAt?.toUtc().toIso8601String(),
      'remind_rule': remindRule,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'deleted_at': '',
    });
  }

  /// The reminder currently stored for the first memo titled [title]; null
  /// is none. Returns local time, like Memo.fromJson does. Lets tests
  /// assert exactly what a save exported over the wire.
  DateTime? remindAtOf(String title) {
    final raw = _memos.firstWhere((m) => m['title'] == title)['remind_at'] as String?;
    if (raw == null || raw.isEmpty) return null;
    return DateTime.parse(raw).toLocal();
  }

  /// Rewrites a memo's reminder, standing in for another device having
  /// changed it.
  void setMemoReminder(String username, String title, DateTime? when) {
    final memo = _memos
        .firstWhere((m) => m['user_id'] == username && m['title'] == title);
    memo['remind_at'] = when?.toUtc().toIso8601String();
  }

  /// The recurrence rule currently stored for the first memo titled [title];
  /// null is none. Lets tests assert exactly what a save exported over the
  /// wire.
  Map<String, dynamic>? remindRuleOf(String title) =>
      memoByTitle(title)['remind_rule'] as Map<String, dynamic>?;

  /// Removes a memo's reminder outright — time point and recurrence rule —
  /// standing in for another device having turned the reminder off.
  void clearMemoReminder(String username, String title) {
    final memo = _memos
        .firstWhere((m) => m['user_id'] == username && m['title'] == title);
    memo['remind_at'] = null;
    memo['remind_rule'] = null;
  }

  /// Deletes a memo, standing in for another device having trashed it.
  void deleteMemoByTitle(String username, String title) {
    final memo = _memos
        .firstWhere((m) => m['user_id'] == username && m['title'] == title);
    memo['deleted_at'] = DateTime.now().toUtc().toIso8601String();
  }

  /// Rewrites a memo's body, standing in for another device having edited
  /// it after this client's last sync.
  void setMemoBody(String username, String title, String body) {
    final memo = _memos
        .firstWhere((m) => m['user_id'] == username && m['title'] == title);
    memo['body'] = body;
  }

  /// Same rules as the real server: trim each name, reject blank or
  /// over-long ones (400 invalid_tag), dedupe keeping first occurrence.
  /// Returns null when any name is invalid.
  static List<String>? _normalizeTags(List<dynamic> names) {
    final out = <String>[];
    for (final raw in names) {
      if (raw is! String) return null;
      final name = raw.trim();
      if (name.isEmpty || name.runes.length > 50) return null;
      if (!out.contains(name)) out.add(name);
    }
    return out;
  }

  Map<String, dynamic> userByName(String username) => _users[username]!;

  /// The body currently stored for the first memo titled [title] — lets
  /// tests assert exactly what a save exported over the wire.
  String bodyOf(String title) =>
      _memos.firstWhere((m) => m['title'] == title)['body'] as String;

  /// The raw stored map for the first memo titled [title] — lets tests
  /// assert fields bodyOf and remindAtOf do not cover (tags, category).
  Map<String, dynamic> memoByTitle(String title) =>
      _memos.firstWhere((m) => m['title'] == title);

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
    if (offline) throw const SocketException('offline');
    final path = request.url.path;
    final segments = path.split('/');
    final resource = segments.length == 5 &&
            (segments[3] == 'memos' ||
                segments[3] == 'categories' ||
                segments[3] == 'users' ||
                segments[3] == 'trash')
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
    } else if (path == '/api/v1/trash' && request.method == 'GET') {
      r = await _withAuth(request, (user) async => _json(200, {
            'memos': _memos
                .where((m) => m['user_id'] == user && (m['deleted_at'] as String).isNotEmpty)
                .toList(),
          }));
    } else if (segments.length == 6 &&
        segments[3] == 'trash' &&
        segments[5] == 'restore' &&
        request.method == 'POST') {
      r = await _withAuth(request, (user) async => _restoreMemo(user, int.tryParse(segments[4])));
    } else if (resource == 'trash' && request.method == 'DELETE') {
      r = await _withAuth(request, (user) async => _purgeMemo(user, resourceId));
    } else if (resource == 'memos' && request.method == 'GET') {
      r = await _withAuth(request, (user) async {
        final match = _memos
            .where((m) =>
                m['id'] == resourceId &&
                m['user_id'] == user &&
                (m['deleted_at'] as String).isEmpty)
            .toList();
        return match.isEmpty ? _json(404, {'error': 'not_found'}) : _json(200, match.first);
      });
    } else if (path == '/api/v1/memos' && request.method == 'GET') {
      r = await _withAuth(request, (user) async {
        final tag = request.url.queryParameters['tag'];
        // Same shape as the real server (T6): q searches title, body, and
        // tags of the user's live memos, every whitespace-separated term
        // ANDed; a tag on top narrows the hits, and so does category_id
        // (T14) — malformed or non-positive ids are a 400, well-formed
        // unknown ones a miss.
        final q = (request.url.queryParameters['q'] ?? '').trim();
        final terms = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
        var match = _memos.where((m) =>
            m['user_id'] == user && (m['deleted_at'] as String).isEmpty);
        bool hits(Map<String, dynamic> m) => terms.every((term) =>
            (m['title'] as String).contains(term) ||
            (m['body'] as String).contains(term) ||
            (m['tags'] as List<String>).any((t) => t.contains(term)));
        if (q.isNotEmpty) {
          match = match.where(hits);
        }
        if (tag != null && tag.isNotEmpty) {
          match = match.where(
              (m) => (m['tags'] as List<String>).contains(tag));
        }
        final categoryId = request.url.queryParameters['category_id'];
        if (categoryId != null) {
          final id = int.tryParse(categoryId);
          if (id == null || id <= 0) {
            return _json(400, {'error': 'invalid_request'});
          }
          match = match.where((m) => m['category_id'] == id);
        }
        return _json(200, {'memos': match.toList()});
      });
    } else if (path == '/api/v1/memos' && request.method == 'POST') {
      r = await _withAuth(request, (user) => _createMemo(request, user));
    } else if (resource == 'memos' && request.method == 'PUT') {
      r = await _withAuth(request, (user) => _updateMemo(request, user, resourceId));
    } else if (resource == 'memos' && request.method == 'DELETE') {
      r = await _withAuth(request, (user) async => _deleteMemo(user, resourceId));
    } else if (path == '/api/v1/tags' && request.method == 'GET') {
      r = await _withAuth(request, (user) async {
        final names = <String>{
          for (final m in _memos.where((m) =>
              m['user_id'] == user && (m['deleted_at'] as String).isEmpty))
            ...(m['tags'] as List<String>),
        }.toList()
          ..sort();
        return _json(200, {'tags': names});
      });
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
    } else if (path == '/api/v1/ai/settings' && request.method == 'GET') {
      r = await _withAuth(request, (user) async => _getAISettings(user));
    } else if (path == '/api/v1/ai/settings' && request.method == 'PUT') {
      r = await _withAuth(request, (user) async => _saveAISettings(request, user));
    } else if (path == '/api/v1/ai/settings/test' && request.method == 'POST') {
      r = await _withAuth(request, (user) async {
        if (!_isAdministrator(user)) return _json(403, {'error': 'administrator_only'});
        aiTestCalls++;
        return _json(200, aiTestResult);
      });
    } else if (path == '/api/v1/agent/messages' && request.method == 'GET') {
      r = await _withAuth(request, (user) async => _json(200, {
            'messages': _conversations[user] ?? <Map<String, dynamic>>[],
          }));
    } else if (path == '/api/v1/agent/messages' && request.method == 'DELETE') {
      r = await _withAuth(request, (user) async {
        _conversations.remove(user);
        agentClearCalls++;
        return http.Response('', 204);
      });
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

  /// The key mask, same rule as the real server: first three characters,
  /// an ellipsis, the last four; anything shorter than 12 is masked outright.
  static String maskApiKey(String key) {
    if (key.isEmpty) return '';
    if (key.length < 12) return '••••';
    return '${key.substring(0, 3)}…${key.substring(key.length - 4)}';
  }

  http.Response _getAISettings(String user) {
    if (!_isAdministrator(user)) return _json(403, {'error': 'administrator_only'});
    return _json(200, {
      'base_url': aiSettings['base_url'],
      'model': aiSettings['model'],
      'api_key': maskApiKey(aiSettings['api_key'] as String),
      'enabled': aiSettings['enabled'],
    });
  }

  /// api_key absent/empty keeps the stored one, a value replaces it — the
  /// same three states the real server implements.
  http.Response _saveAISettings(http.Request request, String user) {
    if (!_isAdministrator(user)) return _json(403, {'error': 'administrator_only'});
    final body = _body(request);
    final apiKey = body['api_key'] as String?;
    if (apiKey != null && apiKey.isNotEmpty) {
      aiSettings['api_key'] = apiKey;
    }
    aiSettings['base_url'] = body['base_url'] as String? ?? '';
    aiSettings['model'] = body['model'] as String? ?? '';
    aiSettings['enabled'] = body['enabled'] as bool? ?? false;
    return _getAISettings(user);
  }

  /// Category assignment mirrors the real server: omitted → 未分类 (create)
  /// or unchanged (update); present but unknown → 400.
  int _resolveCategoryId(Map<String, dynamic> body, {int? current}) {
    final requested = body['category_id'] as int?;
    if (requested == null) return current ?? uncategorizedId;
    if (!_categories.containsKey(requested)) return -1;
    return requested;
  }

  /// Decodes a remind_at request value the way the real server does (T9):
  /// absent → keep (create: none), '' → clear, RFC3339 → set, anything
  /// else → invalid (400).
  (String, DateTime?) _decodeRemindAt(Map<String, dynamic> body) {
    final raw = body['remind_at'];
    if (raw == null) return ('keep', null);
    if (raw is! String) return ('invalid', null);
    if (raw.isEmpty) return ('clear', null);
    final t = DateTime.tryParse(raw);
    return (t == null ? 'invalid' : 'set', t);
  }

  /// Decodes a remind_rule request value the way the real server does
  /// (T70): absent → keep (create: none), '' → clear, object → set. The
  /// real server additionally validates the rule's shape (mode-specific
  /// fields and ranges, 400 otherwise); that contract is pinned by the
  /// server's own seam tests, not re-enacted here.
  (String, Map<String, dynamic>?) _decodeRemindRule(
      Map<String, dynamic> body) {
    final raw = body['remind_rule'];
    if (raw == null) return ('keep', null);
    if (raw == '') return ('clear', null);
    if (raw is Map<String, dynamic>) return ('set', raw);
    return ('invalid', null);
  }

  Future<http.Response> _createMemo(http.Request request, String user) async {
    final body = _body(request);
    final title = (body['title'] as String? ?? '').trim();
    if (title.isEmpty) return _json(400, {'error': 'invalid_request'});
    List<String>? tags;
    if (body['tags'] is List) {
      tags = _normalizeTags(body['tags'] as List);
      if (tags == null) return _json(400, {'error': 'invalid_tag'});
    }
    final categoryId = _resolveCategoryId(body);
    if (categoryId == -1) return _json(400, {'error': 'unknown_category'});
    final (remindOutcome, remindAt) = _decodeRemindAt(body);
    if (remindOutcome == 'invalid') return _json(400, {'error': 'invalid_request'});
    final (ruleOutcome, remindRule) = _decodeRemindRule(body);
    if (ruleOutcome == 'invalid') return _json(400, {'error': 'invalid_request'});
    final now = DateTime.now().toUtc().toIso8601String();
    final memo = {
      'id': _nextMemoId++,
      'user_id': user,
      'category_id': categoryId,
      'title': title,
      'body': body['body'] as String? ?? '',
      'tags': tags ?? <String>[],
      'remind_at':
          remindOutcome == 'set' ? remindAt!.toUtc().toIso8601String() : null,
      'remind_rule': ruleOutcome == 'set' ? remindRule : null,
      'created_at': now,
      'updated_at': now,
      'deleted_at': '',
    };
    _memos.add(memo);
    return _json(201, memo);
  }

  Future<http.Response> _updateMemo(http.Request request, String user, int? id) async {
    final idx = _memos.indexWhere((m) =>
        m['id'] == id &&
        m['user_id'] == user &&
        (m['deleted_at'] as String).isEmpty);
    if (idx == -1) return _json(404, {'error': 'not_found'});
    final body = _body(request);
    final title = (body['title'] as String? ?? '').trim();
    if (title.isEmpty) return _json(400, {'error': 'invalid_request'});
    List<String>? tags;
    if (body['tags'] is List) {
      tags = _normalizeTags(body['tags'] as List);
      if (tags == null) return _json(400, {'error': 'invalid_tag'});
    }
    final categoryId =
        _resolveCategoryId(body, current: _memos[idx]['category_id'] as int);
    if (categoryId == -1) return _json(400, {'error': 'unknown_category'});
    final (remindOutcome, remindAt) = _decodeRemindAt(body);
    if (remindOutcome == 'invalid') return _json(400, {'error': 'invalid_request'});
    final (ruleOutcome, remindRule) = _decodeRemindRule(body);
    if (ruleOutcome == 'invalid') return _json(400, {'error': 'invalid_request'});
    _memos[idx]['title'] = title;
    _memos[idx]['body'] = body['body'] as String? ?? '';
    _memos[idx]['category_id'] = categoryId;
    if (tags != null) _memos[idx]['tags'] = tags;
    if (remindOutcome == 'clear') {
      _memos[idx]['remind_at'] = null;
    } else if (remindOutcome == 'set') {
      _memos[idx]['remind_at'] = remindAt!.toUtc().toIso8601String();
    }
    if (ruleOutcome == 'clear') {
      _memos[idx]['remind_rule'] = null;
    } else if (ruleOutcome == 'set') {
      _memos[idx]['remind_rule'] = remindRule;
    }
    _memos[idx]['updated_at'] = DateTime.now().toUtc().toIso8601String();
    return _json(200, _memos[idx]);
  }

  /// Same as the real server (T5): DELETE moves the memo into the recycle
  /// bin — a soft delete — and one already there looks missing.
  http.Response _deleteMemo(String user, int? id) {
    final idx = _memos.indexWhere((m) =>
        m['id'] == id &&
        m['user_id'] == user &&
        (m['deleted_at'] as String).isEmpty);
    if (idx == -1) return _json(404, {'error': 'not_found'});
    _memos[idx]['deleted_at'] = DateTime.now().toUtc().toIso8601String();
    return http.Response('', 204);
  }

  http.Response _restoreMemo(String user, int? id) {
    final memo = _memoInTrash(user, id);
    if (memo == null) return _json(404, {'error': 'not_found'});
    memo['deleted_at'] = '';
    return http.Response('', 204);
  }

  http.Response _purgeMemo(String user, int? id) {
    final memo = _memoInTrash(user, id);
    if (memo == null) return _json(404, {'error': 'not_found'});
    _memos.remove(memo);
    return http.Response('', 204);
  }

  Map<String, dynamic>? _memoInTrash(String user, int? id) {
    for (final m in _memos) {
      if (m['id'] == id &&
          m['user_id'] == user &&
          (m['deleted_at'] as String).isNotEmpty) {
        return m;
      }
    }
    return null;
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
