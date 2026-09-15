import 'dart:convert';

import 'package:http/http.dart' as http;

import 'recurrence.dart';

/// Talks to the Meridian server's /api/v1 JSON API. Failures surface as
/// ApiException with the HTTP status, so screens can branch on behavior
/// (wrong password vs. unreachable server) without parsing bodies.
class MeridianApi {
  final String baseUrl;
  final http.Client _client;

  MeridianApi({required String baseUrl, http.Client? client})
      : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
        _client = client ?? http.Client();

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    String? token,
    Object? body,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    http.Response response;
    try {
      final req = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) req.body = jsonEncode(body);
      response = await http.Response.fromStream(
        await _client.send(req).timeout(const Duration(seconds: 10)),
      );
    } on Exception {
      throw ApiException.unreachable();
    }
    return _decode(response);
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.statusCode >= 400) {
      String code = 'error';
      try {
        code = (jsonDecode(response.body) as Map<String, dynamic>)['error']
                as String? ??
            code;
      } catch (_) {}
      throw ApiException(statusCode: response.statusCode, code: code);
    }
    if (response.body.isEmpty) return const {};
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<bool> isInitialized() async {
    final body = await _request('GET', '/api/v1/instance');
    return body['initialized'] as bool? ?? false;
  }

  /// Creates the first administrator; the server closes the wizard forever
  /// afterwards (ADR-0001).
  Future<Session> setupAdministrator(String username, String password) async {
    final body = await _request('POST', '/api/v1/setup/administrator',
        body: {'username': username, 'password': password});
    return Session.fromJson(body);
  }

  Future<Session> login(String username, String password) async {
    final body = await _request('POST', '/api/v1/auth/login',
        body: {'username': username, 'password': password});
    return Session.fromJson(body);
  }

  /// The instance taxonomy (ADR-0002): every authenticated user may read it —
  /// clients need it to offer the category picker. Only administrators may
  /// change it, and only via the Web Console.
  Future<List<Category>> categories(String token) async {
    final body = await _request('GET', '/api/v1/categories', token: token);
    return [
      for (final c in body['categories'] as List? ?? [])
        Category.fromJson(c as Map<String, dynamic>),
    ];
  }

  /// Adds a category to the taxonomy. Administrators only; the server
  /// answers 403 for anyone else and 409 for a name that is already taken.
  Future<Category> createCategory(String token, {required String name}) async {
    final data = await _request('POST', '/api/v1/categories', token: token,
        body: {'name': name});
    return Category.fromJson(data);
  }

  /// Deletes a category; its memos fall back to 未分类 server-side. The
  /// built-in cannot be deleted (409).
  Future<void> deleteCategory(String token, {required int id}) async {
    await _request('DELETE', '/api/v1/categories/$id', token: token);
  }

  /// The instance's users, administrators only. Each entry carries
  /// memo_count — the number the delete confirmation dialog must show.
  Future<List<User>> users(String token) async {
    final body = await _request('GET', '/api/v1/users', token: token);
    return [
      for (final u in body['users'] as List? ?? [])
        User.fromJson(u as Map<String, dynamic>),
    ];
  }

  /// Creates an ordinary user with issued credentials. The server answers
  /// 409 for a username that is already taken.
  Future<User> createUser(String token,
      {required String username, required String password}) async {
    final data = await _request('POST', '/api/v1/users', token: token,
        body: {'username': username, 'password': password});
    return User.fromJson(data);
  }

  /// Replaces a user's password; the server ends sessions issued under the
  /// old one.
  Future<void> resetPassword(String token,
      {required int id, required String password}) async {
    await _request('PUT', '/api/v1/users/$id/password', token: token,
        body: {'password': password});
  }

  /// Hard-deletes a user; all of their data disappears with it server-side.
  /// The server answers 409 when the caller targets themselves.
  Future<void> deleteUser(String token, {required int id}) async {
    await _request('DELETE', '/api/v1/users/$id', token: token);
  }

  /// The instance's AI 设置 (ADR-0009), administrators only. apiKey in the
  /// response is the server's mask, never the stored plaintext.
  Future<AISettings> aiSettings(String token) async {
    final body = await _request('GET', '/api/v1/ai/settings', token: token);
    return AISettings.fromJson(body);
  }

  /// Saves the AI 设置. input.apiKey null or empty keeps the stored key —
  /// the key only travels when the administrator typed a new one. Answers
  /// with the saved settings, key masked.
  Future<AISettings> saveAISettings(String token, AISettingsInput input) async {
    final data = await _request('PUT', '/api/v1/ai/settings', token: token,
        body: input.toJson());
    return AISettings.fromJson(data);
  }

  /// Asks the server to dial the saved configuration with one minimal
  /// request; (success, reason) comes back either way — the reason text is
  /// meant to be shown as-is.
  Future<(bool, String?)> testAISettings(String token) async {
    final body = await _request('POST', '/api/v1/ai/settings/test', token: token);
    return (body['success'] as bool? ?? false, body['reason'] as String?);
  }

  /// The signed-in user's own tag names — the autocomplete data source
  /// (T4). Tags never cross users.
  Future<List<String>> tags(String token) async {
    final body = await _request('GET', '/api/v1/tags', token: token);
    return [
      for (final t in body['tags'] as List? ?? []) t as String,
    ];
  }

  /// tag non-null lists only the memos carrying that tag — a body without
  /// the word still matches (T4). categoryId non-null lists only the memos
  /// in that taxonomy category (T14). query non-null full-text searches
  /// title, body, and tags (T6); given together, each narrows the others.
  Future<List<Memo>> memos(String token,
      {String? tag, String? query, int? categoryId}) async {
    final params = <String>[
      if (tag != null) 'tag=${Uri.encodeQueryComponent(tag)}',
      if (query != null) 'q=${Uri.encodeQueryComponent(query)}',
      if (categoryId != null) 'category_id=$categoryId',
    ];
    final suffix = params.isEmpty ? '' : '?${params.join('&')}';
    final body = await _request('GET', '/api/v1/memos$suffix', token: token);
    return [
      for (final m in body['memos'] as List? ?? [])
        Memo.fromJson(m as Map<String, dynamic>),
    ];
  }

  /// One memo by id; another user's — or a trashed one — is
  /// indistinguishable from a missing one (404).
  Future<Memo> memo(String token, {required int id}) async {
    final data = await _request('GET', '/api/v1/memos/$id', token: token);
    return Memo.fromJson(data);
  }

  /// categoryId omitted → the server files the memo under 未分类; tags
  /// omitted → it starts with none; remindAt omitted → it starts with no
  /// reminder; remindRule omitted → it starts with no recurrence (T70).
  /// A non-null tags list is saved as given.
  Future<Memo> createMemo(String token,
      {required String title, String body = '', int? categoryId,
      List<String>? tags, DateTime? remindAt, ReminderRule? remindRule}) async {
    final data = await _request('POST', '/api/v1/memos', token: token, body: {
      'title': title,
      'body': body,
      'category_id': ?categoryId,
      'tags': ?tags,
      'remind_at': ?remindAt?.toUtc().toIso8601String(),
      'remind_rule': ?remindRule?.toJson(),
    });
    return Memo.fromJson(data);
  }

  /// categoryId omitted → the memo keeps its current category; tags omitted
  /// → it keeps its current tags. By default remindAt and remindRule are
  /// always sent — the editor owns the memo's whole state — so null clears
  /// the reminder and a time/rule sets it (T9, T70). keepReminder (the Web
  /// 简易客户端's save path) sends neither field and ignores remindAt and
  /// remindRule: the server keeps the standing ones, so the save cannot
  /// overwrite a reminder another end set or moved after this editor loaded
  /// — a state its hidden reminder UI cannot reflect.
  Future<Memo> updateMemo(String token,
      {required int id, required String title, String body = '',
      int? categoryId, List<String>? tags, DateTime? remindAt,
      ReminderRule? remindRule, bool keepReminder = false}) async {
    final data = await _request('PUT', '/api/v1/memos/$id', token: token, body: {
      'title': title,
      'body': body,
      'category_id': ?categoryId,
      'tags': ?tags,
      if (!keepReminder) ...{
        'remind_at': remindAt?.toUtc().toIso8601String() ?? '',
        'remind_rule': remindRule?.toJson() ?? '',
      },
    });
    return Memo.fromJson(data);
  }

  Future<void> deleteMemo(String token, {required int id}) async {
    await _request('DELETE', '/api/v1/memos/$id', token: token);
  }

  /// The recycle bin (T5): the user's own trashed memos, most recently
  /// deleted first. The recycle bin never empties itself.
  Future<List<Memo>> trash(String token) async {
    final body = await _request('GET', '/api/v1/trash', token: token);
    return [
      for (final m in body['memos'] as List? ?? [])
        Memo.fromJson(m as Map<String, dynamic>),
    ];
  }

  /// Takes a trashed memo back out; it reappears in its original category.
  Future<void> restoreMemo(String token, {required int id}) async {
    await _request('POST', '/api/v1/trash/$id/restore', token: token);
  }

  /// Removes a trashed memo for good; there is no way back.
  Future<void> purgeMemo(String token, {required int id}) async {
    await _request('DELETE', '/api/v1/trash/$id', token: token);
  }

  /// Sends one 智能体 message (#74) and hands back the reply's SSE frames as
  /// [AgentEvent]s. Unlike every other call the reply is a stream — deltas
  /// surface as they arrive, not after the whole reply — so there is no
  /// request timeout here: the server bounds one turn itself
  /// (agentReplyTimeout), and a mid-stream death surfaces as a stream error.
  /// A rejection before the stream starts (bad body, dead credential) throws
  /// ApiException as usual.
  Future<Stream<AgentEvent>> sendAgentMessage(String token,
      {required String content,
      required String localTime,
      required String timezone}) async {
    final req = http.Request('POST', Uri.parse('$baseUrl/api/v1/agent/messages'))
      ..headers['Content-Type'] = 'application/json'
      ..headers['Authorization'] = 'Bearer $token'
      ..body = jsonEncode({
        'content': content,
        'local_time': localTime,
        'timezone': timezone,
      });
    http.StreamedResponse response;
    try {
      response = await _client.send(req);
    } on Exception {
      throw ApiException.unreachable();
    }
    if (response.statusCode != 200) {
      String code = 'error';
      try {
        final body =
            jsonDecode(await response.stream.bytesToString()) as Map;
        code = body['error'] as String? ?? code;
      } catch (_) {}
      throw ApiException(statusCode: response.statusCode, code: code);
    }
    return _sseFrames(response);
  }

  /// The conversation's display record (#74): user and assistant turns only
  /// (protocol rows are filtered server-side); an assistant row may carry
  /// the draft card it proposed.
  Future<List<AgentRecord>> agentMessages(String token) async {
    final body = await _request('GET', '/api/v1/agent/messages', token: token);
    return [
      for (final m in body['messages'] as List? ?? [])
        AgentRecord.fromJson(m as Map<String, dynamic>),
    ];
  }

  /// Clears the conversation's display record (#74); the session itself is
  /// resident and stays. 204 whether or not anything was there.
  Future<void> clearAgentMessages(String token) async {
    await _request('DELETE', '/api/v1/agent/messages', token: token);
  }
}

/// The client's clock at send time as the agent API asks for it (#74):
/// RFC3339 with the local wall time and a numeric offset — the offset that
/// tells the server which of today's hours the user meant by "明天下午".
/// (DateTime.toIso8601String alone is not enough: it stamps no offset at all
/// for a non-UTC DateTime.)
String rfc3339Local(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  final off = t.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
      'T${two(t.hour)}:${two(t.minute)}:${two(t.second)}'
      '$sign${two(off.inHours.abs())}:${two(off.inMinutes.abs() % 60)}';
}

/// One parsed frame of the agent reply stream, one JSON object per SSE
/// "data:" frame (#74): the next display increment, a draft card, the turn's
/// end — or the turn's failure, whose text is safe to show.
sealed class AgentEvent {}

class AgentDeltaEvent extends AgentEvent {
  final String text;
  AgentDeltaEvent(this.text);
}

class AgentDraftEvent extends AgentEvent {
  final AgentDraft draft;
  AgentDraftEvent(this.draft);
}

class AgentDoneEvent extends AgentEvent {
  final bool awaitingInput;
  AgentDoneEvent(this.awaitingInput);
}

class AgentErrorEvent extends AgentEvent {
  final String message;

  /// The machine-readable failure kind the server stamps on the frame:
  /// "not_configured"/"disabled" are the availability gate's two diagnoses
  /// (the page's 请联系管理员 empty states key off them), anything else —
  /// including a frame from an older server that carries no code at all —
  /// is "internal" and speaks as an ordinary error bubble.
  final String code;

  AgentErrorEvent(this.message, {this.code = 'internal'});
}

/// The structured draft card (the glossary's Draft) an agent turn proposes
/// (#75), same shape as the server's agentDraft. There is deliberately no
/// tags field: tags are never the model's to write — the client's card
/// starts empty and only the user fills it.
class AgentDraft {
  final String title;
  final String content;
  final int categoryId;
  final DateTime? remindAt;
  final ReminderRule? remindRule;

  AgentDraft({
    required this.title,
    required this.content,
    required this.categoryId,
    this.remindAt,
    this.remindRule,
  });

  factory AgentDraft.fromJson(Map<String, dynamic> json) => AgentDraft(
        title: json['title'] as String? ?? '',
        content: json['content'] as String? ?? '',
        categoryId: json['category_id'] as int? ?? 0,
        remindAt: parseRemindAt(json['remind_at']),
        remindRule: parseRemindRule(json['remind_rule']),
      );
}

/// One turn of the conversation's display record (GET agentMessages, #74).
class AgentRecord {
  final int id;
  final String role;
  final String content;
  final bool awaitingInput;
  final AgentDraft? draft;

  AgentRecord({
    required this.id,
    required this.role,
    required this.content,
    required this.awaitingInput,
    this.draft,
  });

  factory AgentRecord.fromJson(Map<String, dynamic> json) => AgentRecord(
        id: json['id'] as int,
        role: json['role'] as String,
        content: json['content'] as String? ?? '',
        awaitingInput: json['awaiting_input'] as bool? ?? false,
        draft: json['draft'] is Map<String, dynamic>
            ? AgentDraft.fromJson(json['draft'] as Map<String, dynamic>)
            : null,
      );
}

/// Turns the reply stream's bytes into [AgentEvent]s. The wire is SSE —
/// `data: {json}\n\n` — but chunks can split a line, or a rune, anywhere, so
/// bytes buffer until a newline completes a line. Lines that carry no frame
/// (blanks, field names the protocol does not use) are noise, and an
/// undecodable frame is skipped: the stream never dies on one bad line.
Stream<AgentEvent> _sseFrames(http.StreamedResponse response) async* {
  final parser = _SseParser();
  await for (final chunk in response.stream) {
    for (final event in parser.feed(chunk)) {
      yield event;
    }
  }
}

class _SseParser {
  final List<int> _pending = [];

  List<AgentEvent> feed(List<int> chunk) {
    _pending.addAll(chunk);
    final events = <AgentEvent>[];
    var line = <int>[];
    for (var i = 0; i < _pending.length; i++) {
      if (_pending[i] != 0x0a) {
        line.add(_pending[i]);
        continue;
      }
      final event = _parseLine(line);
      if (event != null) events.add(event);
      line = <int>[];
    }
    _pending
      ..clear()
      ..addAll(line);
    return events;
  }

  AgentEvent? _parseLine(List<int> bytes) {
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.endsWith('\r')) text = text.substring(0, text.length - 1);
    if (!text.startsWith('data:')) return null;
    var rest = text.substring(5);
    if (rest.startsWith(' ')) rest = rest.substring(1);
    try {
      final json = jsonDecode(rest);
      if (json is! Map<String, dynamic>) return null;
      return switch (json['type']) {
        'delta' => AgentDeltaEvent(json['text'] as String? ?? ''),
        'draft' when json['draft'] is Map<String, dynamic> =>
          AgentDraftEvent(
              AgentDraft.fromJson(json['draft'] as Map<String, dynamic>)),
        'done' => AgentDoneEvent(json['awaiting_input'] as bool? ?? true),
        'error' => AgentErrorEvent(json['message'] as String? ?? '回复失败',
            code: json['code'] as String? ?? 'internal'),
        _ => null,
      };
    } on FormatException {
      return null;
    }
  }
}

class Session {
  final String token;
  final User user;

  Session({required this.token, required this.user});

  factory Session.fromJson(Map<String, dynamic> json) => Session(
        token: json['token'] as String,
        user: User.fromJson(json['user'] as Map<String, dynamic>),
      );
}

class User {
  final int id;
  final String username;

  /// 'administrator' or 'user'; only administrators may manage users and the
  /// taxonomy.
  final String role;

  /// How many memos this user owns; set only in the administrator's user
  /// list, where it feeds the delete confirmation dialog.
  final int memoCount;

  User({
    required this.id,
    required this.username,
    this.role = 'user',
    this.memoCount = 0,
  });

  bool get isAdministrator => role == 'administrator';

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as int,
        username: json['username'] as String,
        role: json['role'] as String? ?? 'user',
        memoCount: json['memo_count'] as int? ?? 0,
      );

  /// The API wire shape, shared by the identity store's local encoding
  /// (memo_count is list-only data and stays out).
  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'role': role,
      };
}

/// A save instruction for the AI 设置 (ADR-0009): the non-secret fields go
/// over wholesale. apiKey null or empty keeps the stored key — the field is
/// only populated when the administrator typed a new one.
class AISettingsInput {
  final String baseUrl;
  final String model;
  final bool enabled;
  final String? apiKey;

  AISettingsInput({
    required this.baseUrl,
    required this.model,
    required this.enabled,
    this.apiKey,
  });

  Map<String, dynamic> toJson() => {
        'base_url': baseUrl,
        'model': model,
        'enabled': enabled,
        if (apiKey != null && apiKey!.isNotEmpty) 'api_key': apiKey,
      };
}

/// The instance's AI 设置 as the server reports it (ADR-0009): apiKey is
/// the mask — identifying, not usable. Empty mask means no key is stored.
class AISettings {
  final String baseUrl;
  final String model;
  final String apiKey;
  final bool enabled;

  AISettings({
    required this.baseUrl,
    required this.model,
    required this.apiKey,
    required this.enabled,
  });

  factory AISettings.fromJson(Map<String, dynamic> json) => AISettings(
        baseUrl: json['base_url'] as String? ?? '',
        model: json['model'] as String? ?? '',
        apiKey: json['api_key'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? false,
      );
}

class Category {
  final int id;
  final String name;

  /// True only for the built-in 未分类: permanent, not deletable.
  final bool isBuiltin;

  Category({required this.id, required this.name, required this.isBuiltin});

  factory Category.fromJson(Map<String, dynamic> json) => Category(
        id: json['id'] as int,
        name: json['name'] as String,
        isBuiltin: json['is_builtin'] as bool? ?? false,
      );

  /// The API wire shape, shared by the offline snapshot's encoding.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'is_builtin': isBuiltin,
      };
}

class Memo {
  final int id;
  final String title;
  final String body;

  /// The taxonomy category the memo lives in; the server always sets it
  /// (new memos default to 未分类).
  final int categoryId;

  /// The user's own tags (T4), in saved order; plain text by definition, so
  /// they are rendered verbatim, never as Markdown.
  final List<String> tags;

  /// The memo's reminder time point (T9), in local time; null is none. With
  /// a recurrence rule standing (T70) it is the next trigger time point. It
  /// belongs to the memo, not to any device, so every logged-in client sees
  /// the same one and fires its own local notification (ADR-0004).
  final DateTime? remindAt;

  /// The memo's recurrence rule (T70); null is none. When it stands the
  /// reminder repeats and remindAt moves forward after every firing.
  final ReminderRule? remindRule;

  Memo(
      {required this.id,
      required this.title,
      required this.body,
      required this.categoryId,
      this.tags = const [],
      this.remindAt,
      this.remindRule});

  static DateTime? _parseRemindAt(Object? raw) => parseRemindAt(raw);

  static ReminderRule? _parseRemindRule(Object? raw) => parseRemindRule(raw);

  factory Memo.fromJson(Map<String, dynamic> json) => Memo(
        id: json['id'] as int,
        title: json['title'] as String,
        body: json['body'] as String? ?? '',
        categoryId: json['category_id'] as int? ?? 0,
        tags: [
          for (final t in json['tags'] as List? ?? []) t as String,
        ],
        remindAt: _parseRemindAt(json['remind_at']),
        remindRule: _parseRemindRule(json['remind_rule']),
      );

  /// The API wire shape, shared by the offline snapshot's encoding.
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'category_id': categoryId,
        'tags': tags,
        'remind_at': remindAt?.toUtc().toIso8601String(),
        'remind_rule': remindRule?.toJson(),
      };
}

/// The wire's optional remind_at: RFC3339 string in, local DateTime out,
/// absent or empty means none. Shared by Memo and AgentDraft.
DateTime? parseRemindAt(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toLocal();
}

/// The wire's optional remind_rule object; absent means none. Shared by Memo
/// and AgentDraft.
ReminderRule? parseRemindRule(Object? raw) {
  if (raw is! Map<String, dynamic>) return null;
  return ReminderRule.fromJson(raw);
}

class ApiException implements Exception {
  final int statusCode;
  final String code;

  ApiException({required this.statusCode, required this.code});

  ApiException.unreachable()
      : statusCode = 0,
        code = 'unreachable';

  bool get isUnreachable => statusCode == 0;
  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => 'ApiException($statusCode, $code)';
}
