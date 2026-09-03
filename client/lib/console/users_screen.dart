import 'package:flutter/material.dart';

import '../api_client.dart';

/// User management: the console's account pillar (ADR-0001 — every account
/// after the first is created here). Deleting an account cascades all of its
/// data server-side, so the confirmation dialog must name the memo count
/// before the administrator commits.
class UsersScreen extends StatefulWidget {
  final MeridianApi api;
  final String token;

  const UsersScreen({super.key, required this.api, required this.token});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  late Future<List<User>> _future;
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _creating = false;
  String? _error;
  String? _info;

  @override
  void initState() {
    super.initState();
    _future = widget.api.users(widget.token);
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _future = widget.api.users(widget.token);
    });
  }

  void _clearMessages() {
    _error = null;
    _info = null;
  }

  Future<void> _create() async {
    final username = _username.text.trim();
    if (username.isEmpty || _password.text.trim().isEmpty) {
      setState(() => _error = '用户名和密码不能为空');
      return;
    }
    setState(() {
      _creating = true;
      _clearMessages();
    });
    try {
      await widget.api.createUser(widget.token,
          username: username, password: _password.text);
      _username.clear();
      _password.clear();
      _reload();
    } on ApiException catch (e) {
      setState(() {
        _error = switch (e.code) {
          'username_taken' => '用户名已存在',
          'administrator_only' => '仅管理员可管理用户',
          _ => '创建失败，请重试',
        };
      });
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _resetPassword(User user) async {
    final newPassword = await showDialog<String>(
      context: context,
      builder: (context) => _ResetPasswordDialog(username: user.username),
    );
    if (newPassword == null || newPassword.trim().isEmpty) return;
    try {
      await widget.api.resetPassword(widget.token,
          id: user.id, password: newPassword);
      setState(() => _info = '已重置 ${user.username} 的密码');
    } on ApiException catch (e) {
      setState(() {
        _error = switch (e.code) {
          'administrator_only' => '仅管理员可管理用户',
          _ => '重置失败，请重试',
        };
      });
    }
  }

  Future<void> _delete(User user) async {
    setState(_clearMessages);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除用户 ${user.username}'),
        content: Text(
          user.memoCount == 0
              ? '该用户没有备忘录。删除后其账号及全部数据将一并消失，且无法恢复。'
              : '该用户有 ${user.memoCount} 条备忘录。删除后其账号与全部备忘录（含标签、提醒）将级联硬删除，且无法恢复。',
        ),
        actions: [
          TextButton(
            key: const Key('cancel_delete_button'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm_delete_button'),
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.deleteUser(widget.token, id: user.id);
      _reload();
    } on ApiException catch (e) {
      setState(() {
        _error = switch (e.code) {
          'self_delete' => '不能删除自己的账号',
          'administrator_only' => '仅管理员可管理用户',
          _ => '删除失败，请重试',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<User>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('加载用户失败'),
                const SizedBox(height: 12),
                FilledButton(onPressed: _reload, child: const Text('重试')),
              ],
            ),
          );
        }
        final users = snapshot.data ?? const <User>[];
        return Column(
          children: [
            Expanded(
              child: ListView(
                key: const Key('user_list'),
                children: [
                  for (final user in users)
                    ListTile(
                      key: Key('user_${user.username}'),
                      title: Text(user.username),
                      subtitle: Text(
                          '${user.isAdministrator ? '管理员' : '用户'} · ${user.memoCount} 条备忘录'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: Key('reset_password_${user.id}'),
                            icon: const Icon(Icons.lock_reset),
                            tooltip: '重置密码',
                            onPressed: () => _resetPassword(user),
                          ),
                          // The administrator row offers no delete: removing
                          // one's own account is rejected server-side too.
                          if (!user.isAdministrator)
                            IconButton(
                              key: Key('delete_user_${user.id}'),
                              icon: const Icon(Icons.delete_outline),
                              tooltip: '删除用户',
                              onPressed: () => _delete(user),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            _createForm(),
          ],
        );
      },
    );
  }

  Widget _createForm() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _username,
                  key: const Key('new_username_field'),
                  decoration: const InputDecoration(labelText: '用户名'),
                  onSubmitted: (_) => _create(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _password,
                  key: const Key('new_password_field'),
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '密码'),
                  onSubmitted: (_) => _create(),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                key: const Key('create_user_button'),
                onPressed: _creating ? null : _create,
                icon: const Icon(Icons.person_add_alt),
                label: const Text('创建用户'),
              ),
            ],
          ),
          if (_error != null || _info != null) ...[
            const SizedBox(height: 8),
            if (_error != null)
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
            else
              Text(_info!,
                  style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          ],
        ],
      ),
    );
  }
}

/// The reset dialog owns its text controller so it disposes only when the
/// dialog — exit animation included — is really gone.
class _ResetPasswordDialog extends StatefulWidget {
  final String username;

  const _ResetPasswordDialog({required this.username});

  @override
  State<_ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<_ResetPasswordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('重置 ${widget.username} 的密码'),
      content: TextField(
        controller: _controller,
        key: const Key('reset_password_field'),
        obscureText: true,
        autofocus: true,
        decoration: const InputDecoration(labelText: '新密码'),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirm_reset_button'),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('重置密码'),
        ),
      ],
    );
  }
}
