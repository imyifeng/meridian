import 'package:flutter/material.dart';

import '../api_client.dart';
import '../editor/meridian_editor.dart';
import '../reminders.dart';

/// Title + WYSIWYG body editor (ADR-0006) for creating and editing a memo,
/// plus the category picker: memos live in exactly one taxonomy category
/// (ADR-0002), new ones default to the built-in 未分类. Bodies that leave the
/// v1 format set (tables and the like) display read-only instead of being
/// degraded by the editor. Offline reading is MemoViewScreen's job (T8),
/// not a mode of this screen.
class MemoEditScreen extends StatefulWidget {
  final MeridianApi api;
  final String token;
  final Memo? memo; // null → create mode

  const MemoEditScreen(
      {super.key, required this.api, required this.token, this.memo});

  @override
  State<MemoEditScreen> createState() => _MemoEditScreenState();
}

class _MemoEditScreenState extends State<MemoEditScreen> {
  late final TextEditingController _title;
  late final TextEditingController _tagField;
  late Future<List<Category>> _categories;
  // The body's editor pipeline: parses the stored Markdown once and owns the
  // document while the screen is open. The body itself is only written to
  // storage at save time, serialized as clean Markdown.
  late final MeridianEditorController _bodyEditor =
      MeridianEditorController(widget.memo?.body ?? '');
  // The memo's tags, edited locally and saved as a whole; plus the user's
  // own tag history, the autocomplete source (T4).
  List<String> _tags = const [];
  List<String> _knownTags = const [];
  // The one-shot reminder (T9), edited locally and saved as a whole with
  // the rest of the memo's state; null is none.
  DateTime? _remindAt;
  int? _categoryId;
  bool _busy = false;

  /// Out-of-format bodies are displayed read-only and must reach storage
  /// byte-for-byte — only in-format bodies serialize through the editor.
  bool get _bodyEditable => _bodyEditor.withinFormatSet;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.memo?.title ?? '');
    _tagField = TextEditingController();
    _tags = List.of(widget.memo?.tags ?? const <String>[]);
    _remindAt = widget.memo?.remindAt;
    _categoryId = widget.memo?.categoryId;
    _categories = widget.api.categories(widget.token);
    _loadKnownTags();
  }

  void _loadKnownTags() {
    widget.api.tags(widget.token).then((tags) {
      if (mounted) setState(() => _knownTags = tags);
    }).catchError((_) {
      // Suggestions are a convenience: an empty history beats a broken
      // editor.
      if (mounted) setState(() => _knownTags = const []);
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _tagField.dispose();
    _bodyEditor.dispose();
    super.dispose();
  }

  /// Same rules as the server (T4): trimmed plain text, at most 50 runes,
  /// duplicates collapse.
  void _addTag() {
    final name = _tagField.text.trim();
    if (name.isEmpty) return;
    if (name.runes.length > 50) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('标签最多 50 字')));
      return;
    }
    setState(() {
      if (!_tags.contains(name)) _tags.add(name);
      _tagField.clear();
    });
  }

  void _removeTag(String name) {
    setState(() => _tags.remove(name));
  }

  List<String> get _suggestions {
    final input = _tagField.text.trim();
    if (input.isEmpty) return const [];
    return [
      for (final t in _knownTags)
        if (!_tags.contains(t) && t.startsWith(input)) t,
    ];
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('标题不能为空')));
      return;
    }
    setState(() => _busy = true);
    try {
      final body = _bodyEditable ? _bodyEditor.markdown : widget.memo?.body ?? '';
      if (widget.memo == null) {
        await widget.api.createMemo(widget.token,
            title: title, body: body, categoryId: _categoryId, tags: _tags,
            remindAt: _remindAt);
      } else {
        await widget.api.updateMemo(widget.token,
            id: widget.memo!.id, title: title, body: body,
            categoryId: _categoryId, tags: _tags, remindAt: _remindAt);
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
        content: const Text('删除后会移入回收站，可在回收站中恢复。'),
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
            IconButton(
              key: const Key('delete_button'),
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: _busy ? null : _delete,
            ),
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
            _buildTagSection(),
            const SizedBox(height: 12),
            _buildReminderSection(),
            const SizedBox(height: 12),
            Expanded(child: _buildBodySection()),
          ],
        ),
      ),
    );
  }

  /// The body area: an editable WYSIWYG surface for in-format memos, or a
  /// read-only rendering plus a notice for anything leaving the v1 format
  /// set (ADR-0006) — such content is displayed, never degraded.
  Widget _buildBodySection() {
    if (_bodyEditable) {
      return MeridianEditor(
        key: const Key('body_editor'),
        controller: _bodyEditor,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          key: const Key('readonly_notice'),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              '正文含有当前版本之外的样式（如表格），以只读方式展示',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        Expanded(
          child: MeridianDocumentReader(
            key: const Key('body_readonly'),
            controller: _bodyEditor,
          ),
        ),
      ],
    );
  }

  /// Free-form tags typed by hand (T4): chips for the tags this memo will
  /// carry, plus autocomplete suggestions drawn from the user's own tag
  /// history. Tags are plain text by definition — they are rendered
  /// verbatim, never as Markdown.
  Widget _buildTagSection() {
    final suggestions = _suggestions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _tagField,
          key: const Key('tag_field'),
          decoration: const InputDecoration(labelText: '标签', hintText: '输入后回车添加'),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _addTag(),
          onChanged: (_) => setState(() {}),
          enabled: !_busy,
        ),
        if (_tags.isNotEmpty || suggestions.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final t in _tags)
                InputChip(
                  key: Key('tag_chip_$t'),
                  label: Text(t),
                  deleteIcon: const Icon(Icons.cancel),
                  onDeleted: _busy ? null : () => _removeTag(t),
                ),
              for (final t in suggestions)
                ActionChip(
                  key: Key('tag_suggestion_$t'),
                  label: Text(t),
                  tooltip: '添加标签 $t',
                  onPressed: _busy ? null : () {
                    setState(() {
                      _tags.add(t);
                      _tagField.clear();
                    });
                  },
                ),
            ],
          ),
      ],
    );
  }

  /// The one-shot reminder (T9): a picker row when none is set, otherwise
  /// the standing time with change and clear actions. Editing stays local
  /// until 保存, like the tags it sits next to.
  Widget _buildReminderSection() {
    final remindAt = _remindAt;
    return Row(
      key: const Key('reminder_section'),
      children: [
        const Icon(Icons.alarm, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: remindAt == null
              ? TextButton.icon(
                  key: const Key('set_reminder_button'),
                  icon: const Icon(Icons.notification_add, size: 18),
                  label: const Text('设置提醒'),
                  onPressed: _busy ? null : _pickReminder,
                )
              : Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    Text(formatReminder(remindAt),
                        key: const Key('reminder_value')),
                    TextButton(
                      key: const Key('change_reminder_button'),
                      onPressed: _busy ? null : _pickReminder,
                      child: const Text('修改'),
                    ),
                    TextButton(
                      key: const Key('clear_reminder_button'),
                      onPressed:
                          _busy ? null : () => setState(() => _remindAt = null),
                      child: const Text('取消提醒'),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  /// Date first, then time — a future moment only. The picker offers no
  /// yesterday, and a time at or before now is rejected here: a reminder
  /// set in the past would sit on the memo and silently never fire.
  Future<void> _pickReminder() async {
    final now = DateTime.now();
    final current = _remindAt;
    final initial = current != null && current.isAfter(now) ? current : now;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now,
      lastDate: now.add(const Duration(days: 366)),
      helpText: '选择提醒日期',
    );
    if (!mounted || date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      initialEntryMode: TimePickerEntryMode.input,
      helpText: '选择提醒时间',
    );
    if (!mounted || time == null) return;
    final picked =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!picked.isAfter(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('提醒时间必须晚于当前时间')));
      return;
    }
    setState(() => _remindAt = picked);
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
