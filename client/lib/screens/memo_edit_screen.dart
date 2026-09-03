import 'package:flutter/material.dart';

import '../api_client.dart';

/// Plain-text title + body editor for creating and editing a memo. T1
/// keeps this deliberately minimal; the WYSIWYG editor is a later ticket.
class MemoEditScreen extends StatefulWidget {
  final MeridianApi api;
  final String token;
  final Memo? memo; // null → create mode

  const MemoEditScreen({super.key, required this.api, required this.token, this.memo});

  @override
  State<MemoEditScreen> createState() => _MemoEditScreenState();
}

class _MemoEditScreenState extends State<MemoEditScreen> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.memo?.title ?? '');
    _body = TextEditingController(text: widget.memo?.body ?? '');
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('标题不能为空')));
      return;
    }
    setState(() => _busy = true);
    try {
      if (widget.memo == null) {
        await widget.api.createMemo(widget.token, title: title, body: _body.text);
      } else {
        await widget.api.updateMemo(widget.token,
            id: widget.memo!.id, title: title, body: _body.text);
      }
      if (mounted) Navigator.of(context).pop();
    } on ApiException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('保存失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除备忘录'),
        content: const Text('删除后无法找回。确定删除吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await widget.api.deleteMemo(widget.token, id: widget.memo!.id);
      if (mounted) Navigator.of(context).pop();
    } on ApiException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('删除失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.memo == null ? '新建备忘录' : '编辑备忘录'),
        actions: [
          if (widget.memo != null)
            IconButton(icon: const Icon(Icons.delete_outline), tooltip: '删除', onPressed: _busy ? null : _delete),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('save_button'),
        tooltip: '保存',
        onPressed: _busy ? null : _save,
        child: const Icon(Icons.check),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _title,
              key: const Key('title_field'),
              decoration: const InputDecoration(labelText: '标题'),
              textInputAction: TextInputAction.next,
              enabled: !_busy,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _body,
                key: const Key('body_field'),
                decoration: const InputDecoration(
                  labelText: '正文',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                enabled: !_busy,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
