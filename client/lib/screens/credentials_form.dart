import 'package:flutter/material.dart';

import '../api_client.dart';

/// Shared form for the setup wizard and login: server address, username,
/// password. Screens own validation and error messaging; the app owns
/// navigation.
class CredentialsForm extends StatefulWidget {
  final TextEditingController serverAddress;

  /// False when the form talks to the origin serving it (the Web 简易客户端,
  /// T10): there is no address to type, so the field is not offered.
  final bool showServerAddress;
  final String submitLabel;
  final String buttonKey;
  final Future<void> Function(String username, String password) onSubmit;

  /// Maps an API failure to a message; may also react to it (e.g. navigate).
  final String? Function(ApiException error)? onError;

  const CredentialsForm({
    super.key,
    required this.serverAddress,
    this.showServerAddress = true,
    required this.submitLabel,
    required this.buttonKey,
    required this.onSubmit,
    this.onError,
  });

  @override
  State<CredentialsForm> createState() => _CredentialsFormState();
}

class _CredentialsFormState extends State<CredentialsForm> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(_username.text.trim(), _password.text);
    } on ApiException catch (e) {
      setState(() {
        _error = widget.onError?.call(e) ?? '操作失败，请重试';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Centered and width-capped like the console sign-in: on a wide window
    // (desktop, browser) full-stretch fields read as broken.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.showServerAddress) ...[
                TextField(
                  controller: widget.serverAddress,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: 'http://192.168.1.10:8080',
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _username,
                key: const Key('username_field'),
                decoration: const InputDecoration(labelText: '用户名'),
                autofillHints: const [AutofillHints.username],
                enabled: !_busy,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                key: const Key('password_field'),
                decoration: const InputDecoration(labelText: '密码'),
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                enabled: !_busy,
              ),
              const SizedBox(height: 24),
              FilledButton(
                key: Key(widget.buttonKey),
                onPressed: _busy ? null : _submit,
                child: Text(widget.submitLabel),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
