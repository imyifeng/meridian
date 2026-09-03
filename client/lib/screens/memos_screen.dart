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

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<MemoListData> _load() async {
    final memos = await widget.api.memos(widget.token);
    final categories = await widget.api.categories(widget.token);
    return MemoListData(memos, {for (final c in categories) c.id: c.name});
  }

  void _reload() {
    setState(() {
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
        title: const Text('Meridian'),
        actions: [
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
            return const Center(child: Text('暂无备忘录'));
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
