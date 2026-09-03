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
  Future<Session> setupAdmin(String username, String password) async {
    final body = await _request('POST', '/api/v1/setup/admin',
        body: {'username': username, 'password': password});
    return Session.fromJson(body);
  }

  Future<Session> login(String username, String password) async {
    final body = await _request('POST', '/api/v1/auth/login',
        body: {'username': username, 'password': password});
    return Session.fromJson(body);
  }

  Future<List<Memo>> memos(String token) async {
    final body = await _request('GET', '/api/v1/memos', token: token);
    return [
      for (final m in body['memos'] as List? ?? [])
        Memo.fromJson(m as Map<String, dynamic>),
    ];
  }

  Future<Memo> createMemo(String token,
      {required String title, String body = ''}) async {
    final data = await _request('POST', '/api/v1/memos', token: token,
        body: {'title': title, 'body': body});
    return Memo.fromJson(data);
  }

  Future<Memo> updateMemo(String token,
      {required int id, required String title, String body = ''}) async {
    final data = await _request('PUT', '/api/v1/memos/$id', token: token,
        body: {'title': title, 'body': body});
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
  final String role;

  User({required this.id, required this.username, required this.role});

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as int,
        username: json['username'] as String,
        role: json['role'] as String,
      );
}

class Memo {
  final int id;
  final String title;
  final String body;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  Memo({
    required this.id,
    required this.title,
    required this.body,
    this.createdAt,
    this.updatedAt,
  });

  factory Memo.fromJson(Map<String, dynamic> json) => Memo(
        id: json['id'] as int,
        title: json['title'] as String,
        body: json['body'] as String? ?? '',
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
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
