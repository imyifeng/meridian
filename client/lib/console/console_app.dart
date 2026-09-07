import 'package:flutter/material.dart';

import '../api_client.dart';
import '../screens/credentials_form.dart';
import '../session.dart';
import 'categories_screen.dart';
import 'users_screen.dart';

/// The Web 管理控制台 shell: sign in with instance credentials, then manage
/// the category taxonomy and the instance's users. The server hosts this
/// build at /console/, so every API path is same-origin and no server-address
/// field is needed — unlike the Windows/Android client, the browser session
/// token lives in memory only.
class ConsoleApp extends StatefulWidget {
  /// Same-origin by default; inject a base URL (and client) in tests.
  final MeridianApi? api;

  const ConsoleApp({super.key, this.api});

  @override
  State<ConsoleApp> createState() => _ConsoleAppState();
}

class _ConsoleAppState extends State<ConsoleApp> {
  late final MeridianApi _api;

  /// Required by CredentialsForm's API though the same-origin console never
  /// shows the field it backs.
  final _serverAddress = TextEditingController();
  Session? _session;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? MeridianApi(baseUrl: '');
  }

  @override
  void dispose() {
    _serverAddress.dispose();
    super.dispose();
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
      body: CredentialsForm(
        serverAddress: _serverAddress,
        showServerAddress: false, // the instance is whatever serves this page
        submitLabel: '登录',
        buttonKey: 'console_login_button',
        onSubmit: (username, password) async {
          final session = await _api.login(username, password);
          setState(() => _session = session);
        },
        onError: loginErrorMessage,
      ),
    );
  }

  Widget _consoleScaffold() {
    final session = _session!;
    // One session value carries the endpoint-plus-credential to every
    // console screen; the wire session stays only for the role check.
    final meridian = MeridianSession(api: _api, token: session.token);
    final signOut = IconButton(
      icon: const Icon(Icons.logout),
      tooltip: '退出登录',
      onPressed: _signOut,
    );
    // User management is administrator business: everyone else gets the
    // taxonomy view alone.
    if (!session.user.isAdministrator) {
      return Scaffold(
        appBar: AppBar(title: const Text('Meridian 管理控制台'), actions: [signOut]),
        body: CategoriesScreen(session: meridian, canManage: false),
      );
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Meridian 管理控制台'),
          actions: [signOut],
          bottom: const TabBar(
            tabs: [Tab(text: '分类管理'), Tab(text: '用户管理')],
          ),
        ),
        body: TabBarView(
          children: [
            CategoriesScreen(session: meridian, canManage: true),
            UsersScreen(session: meridian),
          ],
        ),
      ),
    );
  }
}
