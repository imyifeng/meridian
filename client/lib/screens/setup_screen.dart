import 'package:flutter/material.dart';

import '../api_client.dart';
import 'credentials_form.dart';

/// Setup Wizard entry on an uninitialized instance: create the first
/// administrator. After this succeeds the instance closes the wizard
/// forever (ADR-0001).
class SetupScreen extends StatelessWidget {
  final TextEditingController serverAddress;
  final MeridianApi api;
  final Future<void> Function(Session session) onAuthenticated;

  /// The wizard only closes by completing setup — or by discovering the
  /// instance was initialized elsewhere mid-wizard (409), in which case
  /// the user must be sent to login.
  final VoidCallback onAlreadyInitialized;

  const SetupScreen({
    super.key,
    required this.serverAddress,
    required this.api,
    required this.onAuthenticated,
    required this.onAlreadyInitialized,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('初始化 Meridian')),
      body: CredentialsForm(
        serverAddress: serverAddress,
        submitLabel: '创建管理员',
        buttonKey: 'create_administrator_button',
        onSubmit: (username, password) async {
          final session = await api.setupAdministrator(username, password);
          await onAuthenticated(session);
        },
        onError: (e) {
          if (e.statusCode == 409) {
            onAlreadyInitialized();
            return '实例已初始化过，请直接登录';
          }
          if (e.isUnreachable) return '无法连接服务器，请检查服务器地址';
          return '创建失败，请重试';
        },
      ),
    );
  }
}
