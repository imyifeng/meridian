import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'screens/login_screen.dart';
import 'screens/memos_screen.dart';
import 'screens/setup_screen.dart';
import 'token_store.dart';

enum AppState { loading, setup, login, memos, error }

/// MeridianApp wires the server address, the credential store, and the
/// screen flow: setup wizard on an uninitialized instance, otherwise
/// login (skipped when a stored credential still works), then memos.
class MeridianApp extends StatefulWidget {
  final String baseUrl;
  final TokenStore tokenStore;

  /// Transport override for UI seam tests; production uses the default
  /// socket-based client.
  final http.Client? apiClient;

  const MeridianApp({
    super.key,
    required this.baseUrl,
    required this.tokenStore,
    this.apiClient,
  });

  @override
  State<MeridianApp> createState() => _MeridianAppState();
}

class _MeridianAppState extends State<MeridianApp> {
  late final TextEditingController _serverAddress;
  AppState _state = AppState.loading;
  String? _token;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _serverAddress = TextEditingController(text: widget.baseUrl);
    _bootstrap();
  }

  @override
  void dispose() {
    _serverAddress.dispose();
    super.dispose();
  }

  MeridianApi _api() =>
      MeridianApi(baseUrl: _serverAddress.text.trim(), client: widget.apiClient);

  Future<void> _bootstrap() async {
    setState(() => _state = AppState.loading);
    try {
      final initialized = await _api().isInitialized();
      if (!initialized) {
        setState(() => _state = AppState.setup);
        return;
      }
      final token = await widget.tokenStore.read();
      if (token == null) {
        setState(() => _state = AppState.login);
        return;
      }
      await _api().memos(token); // prove the stored credential still works
      setState(() {
        _token = token;
        _state = AppState.memos;
      });
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        await widget.tokenStore.clear();
        setState(() => _state = AppState.login);
      } else {
        setState(() {
          _message = '无法连接服务器，请检查服务器地址后重试';
          _state = AppState.error;
        });
      }
    }
  }

  Future<void> _authenticated(Session session) async {
    await widget.tokenStore.write(session.token);
    setState(() {
      _token = session.token;
      _state = AppState.memos;
    });
  }

  void _signedOut() {
    widget.tokenStore.clear();
    setState(() {
      _token = null;
      _state = AppState.login;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Meridian',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: switch (_state) {
        AppState.loading => const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
        AppState.setup => SetupScreen(
            serverAddress: _serverAddress,
            api: _api(),
            onAuthenticated: _authenticated,
            onAlreadyInitialized: () => setState(() => _state = AppState.login),
          ),
        AppState.login => LoginScreen(
            serverAddress: _serverAddress,
            api: _api(),
            onAuthenticated: _authenticated,
          ),
        AppState.memos => MemosScreen(
            api: _api(),
            token: _token!,
            onSignOut: _signedOut,
          ),
        AppState.error => _errorScaffold(),
      },
    );
  }

  Widget _errorScaffold() {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_message),
            const SizedBox(height: 12),
            FilledButton(onPressed: _bootstrap, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
