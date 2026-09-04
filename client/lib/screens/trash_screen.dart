import 'package:flutter/material.dart';

import '../api_client.dart';

/// The recycle bin (T5): every trashed memo of the signed-in user, most
/// recently deleted first. Restore puts a memo back into its original
/// category; purging asks once and is then final. The bin never empties
/// itself.
class TrashScreen extends StatefulWidget {
  final MeridianApi api;
  final String token;

  const TrashScreen({super.key, required this.api, required this.token});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  late Future<List<Memo>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.trash(widget.token);
  }

  void _reload() {
    setState(() {
      _future = widget.api.trash(widget.token);
    });
  }

  Future<void> _restore(Memo memo) async {
    try {
      await widget.api.restoreMemo(widget.token, id: memo.id);
      _reload();
    } on ApiException {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('恢复失败，请重试')));
      }
    }
  }

  Future<void> _purge(Memo memo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('彻底删除'),
        content: const Text('彻底删除后无法恢复。确定删除吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.purgeMemo(widget.token, id: memo.id);
      _reload();
    } on ApiException {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('删除失败，请重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('回收站')),
      body: FutureBuilder<List<Memo>>(
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
                  const Text('加载回收站失败'),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _reload, child: const Text('重试')),
                ],
              ),
            );
          }
          final memos = snapshot.data ?? const <Memo>[];
          if (memos.isEmpty) {
            return const Center(child: Text('回收站是空的'));
          }
          return ListView.builder(
            key: const Key('trash_list'),
            itemCount: memos.length,
            itemBuilder: (context, i) {
              final memo = memos[i];
              return ListTile(
                title: Text(memo.title),
                subtitle: memo.body.isEmpty ? null : Text(memo.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: Key('restore_button_${memo.id}'),
                      icon: const Icon(Icons.restore_from_trash_outlined),
                      tooltip: '恢复',
                      onPressed: () => _restore(memo),
                    ),
                    IconButton(
                      key: Key('purge_button_${memo.id}'),
                      icon: const Icon(Icons.delete_forever_outlined),
                      tooltip: '彻底删除',
                      onPressed: () => _purge(memo),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
