import 'dart:convert';

import 'package:http/http.dart' as http;

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

  /// The instance's accounts, administrators only. Each entry carries
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

  /// Hard-deletes an account; all of its data disappears with it server-side.
  /// The server answers 409 when the caller targets their own account.
  Future<void> deleteUser(String token, {required int id}) async {
    await _request('DELETE', '/api/v1/users/$id', token: token);
  }

  Future<List<Memo>> memos(String token) async {
    final body = await _request('GET', '/api/v1/memos', token: token);
    return [
      for (final m in body['memos'] as List? ?? [])
        Memo.fromJson(m as Map<String, dynamic>),
    ];
  }  /// categoryId omitted → the server files the memo under 未分类.
  Future<Memo> createMemo(String token,
      {required String title, String body = '', int? categoryId}) async {
    final data = await _request('POST', '/api/v1/memos', token: token, body: {
      'title': title,
      'body': body,
      'category_id': ?categoryId,
    });
    return Memo.fromJson(data);
  }

  /// categoryId omitted → the memo keeps its current category.
  Future<Memo> updateMemo(String token,
      {required int id, required String title, String body = '',
      int? categoryId}) async {
    final data = await _request('PUT', '/api/v1/memos/$id', token: token, body: {
      'title': title,
      'body': body,
      'category_id': ?categoryId,
    });
    return Memo.fromJson(data);
  }

  Future<void> deleteMemo(String token, {required int id}) async {
    await _request('DELETE', '/api/v1/memos/$id', token: token);
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

  /// How many memos this account owns; set only in the administrator's user
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
}

class Memo {
  final int id;
  final String title;
  final String body;

  /// The taxonomy category the memo lives in; the server always sets it
  /// (new memos default to 未分类).
  final int categoryId;

  Memo(
      {required this.id,
      required this.title,
      required this.body,
      required this.categoryId});

  factory Memo.fromJson(Map<String, dynamic> json) => Memo(
        id: json['id'] as int,
        title: json['title'] as String,
        body: json['body'] as String? ?? '',
        categoryId: json['category_id'] as int? ?? 0,
      );
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
