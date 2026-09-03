import 'package:flutter/material.dart';

import '../api_client.dart';
import 'memo_edit_screen.dart';

/// The memo list: every memo of the signed-in user, newest first, each with
/// its taxonomy category (ADR-0002).
class MemosScreen extends StatefulWidget {
  final MeridianApi api;
  final String token;
  final VoidCallback onSignOut;

  const MemosScreen({
    super.key,
    required this.api,
    required this.token,
    required this.onSignOut,
  });

  @override
  State<MemosScreen> createState() => _MemosScreenState();
}

class _MemosScreenState extends State<MemosScreen> {
  late Future<MemoListData> _future;
  String? _filterTag;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<MemoListData> _load() async {
    // tag non-null asks the server for only the memos carrying it — a memo
    // whose body never mentions the word still matches (T4).
    final memos = await widget.api.memos(widget.token, tag: _filterTag);
    final categories = await widget.api.categories(widget.token);
    return MemoListData(memos, {for (final c in categories) c.id: c.name});
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  /// Offers the user's own tag history (T4); picking one filters the list.
  Future<void> _pickFilter() async {
    List<String> tags;
    try {
      tags = await widget.api.tags(widget.token);
    } on ApiException {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('加载标签失败')));
      }
      return;
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: tags.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('还没有用过的标签'),
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final t in tags)
                      ListTile(
                        key: Key('filter_tag_$t'),
                        leading: const Icon(Icons.label_outline),
                        title: Text(t),
                        onTap: () => Navigator.of(context).pop(t),
                      ),
                  ],
                ),
              ),
      ),
    );
    if (picked == null) return;
    setState(() {
      _filterTag = picked;
      _future = _load();
    });
  }

  void _clearFilter() {
    setState(() {
      _filterTag = null;
      _future = _load();
    });
  }

  Future<void> _openEditor([Memo? memo]) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MemoEditScreen(api: widget.api, token: widget.token, memo: memo),
    ));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_filterTag == null ? 'Meridian' : '标签：$_filterTag'),
        actions: [
          if (_filterTag != null)
            IconButton(
              key: const Key('clear_filter_button'),
              icon: const Icon(Icons.close),
              tooltip: '清除筛选',
              onPressed: _clearFilter,
            ),
          IconButton(
            key: const Key('filter_button'),
            icon: const Icon(Icons.filter_list),
            tooltip: '按标签筛选',
            onPressed: _pickFilter,
          ),
          IconButton(icon: const Icon(Icons.logout), tooltip: '退出登录', onPressed: widget.onSignOut),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('new_memo_button'),
        tooltip: '新建备忘录',
        onPressed: _openEditor,
        child: const Icon(Icons.add),
      ),
      body: FutureBuilder<MemoListData>(
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
                  const Text('加载备忘录失败'),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _reload, child: const Text('重试')),
                ],
              ),
            );
          }
          final memos = snapshot.data?.memos ?? const <Memo>[];
          final categoryNames = snapshot.data?.categoryNames ?? const {};
          if (memos.isEmpty) {
            return Center(
              child: Text(_filterTag == null ? '暂无备忘录' : '该标签下暂无备忘录'),
            );
          }
          return ListView.builder(
            key: const Key('memo_list'),
            itemCount: memos.length,
            itemBuilder: (context, i) {
              final memo = memos[i];
              return ListTile(
                title: Text(memo.title),
                subtitle: memo.body.isEmpty ? null : Text(memo.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Text(categoryNames[memo.categoryId] ?? ''),
                onTap: () => _openEditor(memo),
              );
            },
          );
        },
      ),
    );
  }
}

/// One loaded screenful: the user's memos plus the taxonomy names, fetched
/// together so each row can show the category it lives in.
class MemoListData {
  final List<Memo> memos;
  final Map<int, String> categoryNames;

  MemoListData(this.memos, this.categoryNames);
}
