import 'package:flutter/material.dart';

import '../api_client.dart';

/// Plain-text title + body editor for creating and editing a memo, plus the
/// category picker: memos live in exactly one taxonomy category (ADR-0002),
/// new ones default to the built-in 未分类. The WYSIWYG editor is a later
/// ticket.
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
  late Future<List<Category>> _categories;
  int? _categoryId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.memo?.title ?? '');
    _body = TextEditingController(text: widget.memo?.body ?? '');
    _categoryId = widget.memo?.categoryId;
    _categories = widget.api.categories(widget.token);
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
        await widget.api.createMemo(widget.token,
            title: title, body: _body.text, categoryId: _categoryId);
      } else {
        await widget.api.updateMemo(widget.token,
            id: widget.memo!.id, title: title, body: _body.text, categoryId: _categoryId);
      }
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) {
        final message =
            e.code == 'unknown_category' ? '该分类已不存在，请重新选择' : '保存失败，请重试';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
            // The taxonomy is fixed (ADR-0002): pick among existing
            // categories, never type a new one.
            FutureBuilder<List<Category>>(
              future: _categories,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                        width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  );
                }
                if (snapshot.hasError) {
                  return Row(
                    children: [
                      const Text('分类加载失败'),
                      TextButton(onPressed: _reloadCategories, child: const Text('重试')),
                    ],
                  );
                }
                final categories = snapshot.data ?? const <Category>[];
                // An unknown stored category (deleted elsewhere meanwhile)
                // falls back to the built-in one.
                var selected = _categoryId;
                if (categories.every((c) => c.id != selected)) {
                  selected = _defaultCategoryId(categories);
                }
                if (selected != _categoryId) {
                  _categoryId = selected;
                }
                return DropdownButtonFormField<int>(
                  key: const Key('category_dropdown'),
                  initialValue: _categoryId,
                  decoration: const InputDecoration(labelText: '分类'),
                  items: [
                    for (final c in categories)
                      DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _categoryId = value),
                );
              },
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

  void _reloadCategories() {
    setState(() => _categories = widget.api.categories(widget.token));
  }

  int? _defaultCategoryId(List<Category> categories) {
    for (final c in categories) {
      if (c.isBuiltin) return c.id;
    }
    return categories.isEmpty ? null : categories.first.id;
  }
}
