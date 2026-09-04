import 'package:flutter/material.dart';

import '../api_client.dart';
import 'credentials_form.dart';

/// Login with username + password against the instance at the given
/// server address.
class LoginScreen extends StatelessWidget {
  final TextEditingController serverAddress;
  final MeridianApi api;

  /// False in the Web 简易客户端 (T10): same-origin, no address field.
  final bool showServerAddress;
  final Future<void> Function(Session session) onAuthenticated;

  const LoginScreen({
    super.key,
    required this.serverAddress,
    required this.api,
    this.showServerAddress = true,
    required this.onAuthenticated,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('登录 Meridian')),
      body: CredentialsForm(
        serverAddress: serverAddress,
        showServerAddress: showServerAddress,
        submitLabel: '登录',
        buttonKey: 'login_button',
        onSubmit: (username, password) async {
          final session = await api.login(username, password);
          await onAuthenticated(session);
        },
        onError: (e) {
          if (e.statusCode == 401) return '用户名或密码错误';
          if (e.isUnreachable) return '无法连接服务器，请检查服务器地址';
          return '登录失败，请重试';
        },
      ),
    );
  }
}
