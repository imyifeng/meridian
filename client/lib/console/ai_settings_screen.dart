import 'package:flutter/material.dart';

import '../api_client.dart';
import '../session.dart';

/// AI 设置 (ADR-0009): the instance's single LLM access configuration. The
/// saved Base URL and model echo back; the API key never does — the field
/// starts empty (leaving it empty keeps the stored key) and the server's
/// mask shows beside it. 测试连接 dials the *saved* configuration from the
/// server, so it reports on what is stored, not on half-typed edits.
///
/// A body without its own Scaffold: the console shell owns the AppBar and
/// the 分类/用户/AI 设置 tabs. Administrator only — the shell does not even
/// offer the tab to anyone else.
class AISettingsScreen extends StatefulWidget {
  final MeridianSession session;

  const AISettingsScreen({super.key, required this.session});

  @override
  State<AISettingsScreen> createState() => _AISettingsScreenState();
}

class _AISettingsScreenState extends State<AISettingsScreen> {
  late Future<AISettings> _future;
  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _apiKey = TextEditingController();
  bool _enabled = false;
  bool _loaded = false;
  bool _saving = false;
  bool _testing = false;
  String? _info;
  String? _error;
  String? _testResult;
  bool _testSuccess = false;

  @override
  void initState() {
    super.initState();
    _future = widget.session.api.aiSettings(widget.session.token);
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _loaded = false;
      _future = widget.session.api.aiSettings(widget.session.token);
    });
  }

  /// Echoes one loaded snapshot into the form, once per load.
  void _adopt(AISettings settings) {
    _baseUrl.text = settings.baseUrl;
    _model.text = settings.model;
    _apiKey.text = '';
    _enabled = settings.enabled;
    _loaded = true;
  }

  void _clearMessages() {
    _info = null;
    _error = null;
  }

  Future<void> _save() async {
    setState(_clearMessages);
    setState(() => _saving = true);
    try {
      final saved = await widget.session.api.saveAISettings(
        widget.session.token,
        AISettingsInput(
          baseUrl: _baseUrl.text.trim(),
          model: _model.text.trim(),
          enabled: _enabled,
          apiKey: _apiKey.text,
        ),
      );
      _adopt(saved);
      setState(() => _info = '已保存');
    } on ApiException catch (e) {
      setState(() {
        _error = switch (e.code) {
          'invalid_request' => '无法保存：启用前需填写 Base URL 与模型名，且 Base URL 须为 http(s) 地址',
          'administrator_only' => '仅管理员可修改 AI 设置',
          _ => '保存失败，请重试',
        };
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    setState(() {
      _clearMessages();
      _testing = true;
      _testResult = null;
    });
    try {
      final (success, reason) =
          await widget.session.api.testAISettings(widget.session.token);
      setState(() {
        _testSuccess = success;
        _testResult = success ? '连接成功' : (reason ?? '连接失败');
      });
    } on ApiException {
      setState(() => _testResult = '测试请求失败，请重试');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AISettings>(
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
                const Text('加载 AI 设置失败'),
                const SizedBox(height: 12),
                FilledButton(onPressed: _reload, child: const Text('重试')),
              ],
            ),
          );
        }
        if (!_loaded) _adopt(snapshot.data!);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _baseUrl,
                key: const Key('ai_base_url_field'),
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  hintText: '如：https://api.example.com/v1',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _model,
                key: const Key('ai_model_field'),
                decoration: const InputDecoration(
                  labelText: '模型名',
                  hintText: '如：meridian-mini',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiKey,
                key: const Key('ai_api_key_field'),
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: '留空保留既存',
                  helperText: snapshot.data!.apiKey.isEmpty
                      ? '尚未设置'
                      // The server's mask, never the key itself (ADR-0009).
                      : '当前已保存：${snapshot.data!.apiKey}',
                ),
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                key: const Key('ai_enabled_switch'),
                title: const Text('启用智能体'),
                subtitle: const Text('关闭后所有用户都无法使用智能体'),
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilledButton.icon(
                    key: const Key('ai_save_button'),
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    key: const Key('ai_test_button'),
                    onPressed: _testing ? null : _test,
                    icon: const Icon(Icons.network_check),
                    label: const Text('测试连接'),
                  ),
                ],
              ),
              if (_info != null || _error != null || _testResult != null) ...[
                const SizedBox(height: 12),
                if (_error != null)
                  Text(
                    _error!,
                    key: const Key('ai_save_error'),
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  )
                else if (_info != null)
                  Text(
                    _info!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.primary),
                  ),
                if (_testResult != null)
                  Text(
                    _testResult!,
                    key: const Key('ai_test_result'),
                    style: TextStyle(
                      color: _testSuccess
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
