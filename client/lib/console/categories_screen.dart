import 'package:flutter/material.dart';

import '../api_client.dart';

/// Category taxonomy management (ADR-0002): the only place in Meridian where
/// the fixed set of categories can grow or shrink, administrator only. The
/// built-in 未分类 never offers a delete affordance. Non-administrators may
/// look, but see no management controls at all — the server rejects their
/// writes regardless (the API is the wall, this is the signpost).
///
/// A body without its own Scaffold: the console shell owns the AppBar and
/// the 分类/用户 tabs.
class CategoriesScreen extends StatefulWidget {
  final MeridianApi api;
  final String token;

  /// False for non-administrator accounts: read-only view.
  final bool canManage;

  const CategoriesScreen({
    super.key,
    required this.api,
    required this.token,
    required this.canManage,
  });

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  late Future<List<Category>> _future;
  final _name = TextEditingController();
  bool _adding = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _future = widget.api.categories(widget.token);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _future = widget.api.categories(widget.token);
    });
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '分类名不能为空');
      return;
    }
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      await widget.api.createCategory(widget.token, name: name);
      _name.clear();
      _reload();
    } on ApiException catch (e) {
      setState(() {
        _error = switch (e.code) {
          'name_taken' => '已存在同名分类',
          'administrator_only' => '仅管理员可管理分类',
          _ => '添加失败，请重试',
        };
      });
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _delete(Category category) async {
    setState(() => _error = null);
    try {
      await widget.api.deleteCategory(widget.token, id: category.id);
      _reload();
    } on ApiException catch (e) {
      setState(() {
        _error = switch (e.code) {
          'builtin_category' => '未分类不可删除',
          'administrator_only' => '仅管理员可管理分类',
          _ => '删除失败，请重试',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: FutureBuilder<List<Category>>(
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
                      const Text('加载分类失败'),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _reload, child: const Text('重试')),
                    ],
                  ),
                );
              }
              final categories = snapshot.data ?? const <Category>[];
              return ListView(
                key: const Key('category_list'),
                children: [
                  for (final category in categories)
                    ListTile(
                      key: Key('category_${category.name}'),
                      title: Text(category.name),
                      trailing: category.isBuiltin
                          ? const Tooltip(message: '系统内置，不可删除', child: Text('内置'))
                          : (widget.canManage
                              ? IconButton(
                                  key: Key('delete_category_${category.id}'),
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: '删除分类',
                                  onPressed: () => _delete(category),
                                )
                              : null),
                    ),
                ],
              );
            },
          ),
        ),
        widget.canManage ? _addForm() : _readOnlyBanner(),
      ],
    );
  }

  Widget _addForm() {
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
                  controller: _name,
                  key: const Key('category_name_field'),
                  decoration: const InputDecoration(labelText: '新分类名称', hintText: '如：工作、学习、生活'),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                key: const Key('add_category_button'),
                onPressed: _adding ? null : _add,
                icon: const Icon(Icons.add),
                label: const Text('添加分类'),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }

  Widget _readOnlyBanner() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        '仅管理员可管理分类',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        textAlign: TextAlign.center,
      ),
    );
  }
}
