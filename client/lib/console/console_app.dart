import 'package:flutter/material.dart';

import '../api_client.dart';
import 'categories_screen.dart';

/// The Web 管理控制台 shell: sign in with an instance account, then manage
/// the category taxonomy. The server hosts this build at /console/, so every
/// API path is same-origin and no server-address field is needed — unlike
/// the Windows/Android client, the browser session token lives in memory
/// only.
class ConsoleApp extends StatefulWidget {
  /// Same-origin by default; inject a base URL (and client) in tests.
  final MeridianApi? api;

  const ConsoleApp({super.key, this.api});

  @override
  State<ConsoleApp> createState() => _ConsoleAppState();
}

class _ConsoleAppState extends State<ConsoleApp> {
  late final MeridianApi _api;
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  Session? _session;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? MeridianApi(baseUrl: '');
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await _api.login(_username.text.trim(), _password.text);
      setState(() => _session = session);
    } on ApiException catch (e) {
      setState(() {
        _error = switch (e.statusCode) {
          401 => '用户名或密码错误',
          0 => '无法连接服务器',
          _ => '登录失败，请重试',
        };
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _signOut() {
    setState(() => _session = null);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Meridian 管理控制台',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: _session == null ? _loginScaffold() : _consoleScaffold(),
    );
  }

  Widget _loginScaffold() {
    return Scaffold(
      appBar: AppBar(title: const Text('Meridian 管理控制台')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _username,
                  key: const Key('username_field'),
                  decoration: const InputDecoration(labelText: '用户名'),
                  enabled: !_busy,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  key: const Key('password_field'),
                  decoration: const InputDecoration(labelText: '密码'),
                  obscureText: true,
                  enabled: !_busy,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('console_login_button'),
                  onPressed: _busy ? null : _signIn,
                  child: const Text('登录'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _consoleScaffold() {
    return CategoriesScreen(api: _api, token: _session!.token, onSignOut: _signOut);
  }
}
