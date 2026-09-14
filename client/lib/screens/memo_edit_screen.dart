import 'package:flutter/material.dart';

import '../api_client.dart';
import '../recurrence.dart';
import '../reminders.dart';
import '../session.dart';

/// Title + plain-text body editor (ADR-0008) for creating and editing a
/// memo, plus the category picker: memos live in exactly one taxonomy
/// category (ADR-0002), new ones default to the built-in 未分类. Offline
/// reading is MemoViewScreen's job (T8), not a mode of this screen.
class MemoEditScreen extends StatefulWidget {
  final MeridianSession session;
  final Memo? memo; // null → create mode

  /// False in the Web 简易客户端 (T10): the reminder row is not offered.
  /// What the editor does not show it must not write: the save then omits
  /// the reminder field entirely, so a reminder another end set or moved
  /// after this editor loaded survives instead of being overwritten by the
  /// stale value riding along.
  final bool showReminder;

  /// Clock for the reminder's future-only check ("a reminder set in the
  /// past would sit on the memo and silently never fire"); production uses
  /// the wall clock, tests inject a fixed one.
  final DateTime Function()? now;

  const MemoEditScreen({
    super.key,
    required this.session,
    this.showReminder = true,
    this.now,
    this.memo,
  });

  @override
  State<MemoEditScreen> createState() => _MemoEditScreenState();
}

class _MemoEditScreenState extends State<MemoEditScreen> {
  late final TextEditingController _title;
  // The body is plain text (ADR-0008): an ordinary text field, saved
  // verbatim — no conversion, no migration of stored content.
  late final TextEditingController _body =
      TextEditingController(text: widget.memo?.body ?? '');
  late final TextEditingController _tagField;
  late Future<List<Category>> _categories;
  // The memo's tags, edited locally and saved as a whole; plus the user's
  // own tag history, the autocomplete source (T4).
  List<String> _tags = const [];
  List<String> _knownTags = const [];
  // The reminder (T9), edited locally and saved as a whole with the rest of
  // the memo's state; null is none. With a recurrence rule standing (T70)
  // it is the next trigger time point, recomputed here whenever the rule is
  // picked; the scheduler advances it after every firing.
  DateTime? _remindAt;

  /// The reminder's recurrence rule (T70); null is a one-shot reminder or
  /// none at all. Saved as a whole alongside _remindAt — clearing the
  /// reminder clears both.
  ReminderRule? _remindRule;
  int? _categoryId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.memo?.title ?? '');
    _tagField = TextEditingController();
    _tags = List.of(widget.memo?.tags ?? const <String>[]);
    _remindAt = widget.memo?.remindAt;
    _remindRule = widget.memo?.remindRule;
    _categoryId = widget.memo?.categoryId;
    _categories = widget.session.api.categories(widget.session.token);
    _loadKnownTags();
  }

  void _loadKnownTags() {
    widget.session.api.tags(widget.session.token).then((tags) {
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
    _body.dispose();
    _tagField.dispose();
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
      final body = _body.text;
      if (widget.memo == null) {
        await widget.session.api.createMemo(widget.session.token,
            title: title, body: body, categoryId: _categoryId, tags: _tags,
            remindAt: _remindAt, remindRule: _remindRule);
      } else {
        await widget.session.api.updateMemo(widget.session.token,
            id: widget.memo!.id, title: title, body: body,
            categoryId: _categoryId, tags: _tags,
            remindAt: widget.showReminder ? _remindAt : null,
            remindRule: widget.showReminder ? _remindRule : null,
            keepReminder: !widget.showReminder);
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
      await widget.session.api.deleteMemo(widget.session.token, id: widget.memo!.id);
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
            if (widget.showReminder) ...[
              const SizedBox(height: 12),
              _buildReminderSection(),
            ],
            const SizedBox(height: 12),
            Expanded(
              // Plain-text body (ADR-0008): an ordinary multiline field that
              // starts at the top, saved verbatim.
              child: TextField(
                controller: _body,
                key: const Key('body_editor'),
                maxLines: null,
                expands: true,
                keyboardType: TextInputType.multiline,
                textAlignVertical: TextAlignVertical.top,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: '正文',
                  alignLabelWithHint: true,
                ),
              ),
            ),
          ],
        ),
      ),
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

  /// The reminder (T9/T70): with none standing, one-shot and recurring
  /// entries side by side; a one-shot shows its time, a recurring one its
  /// rule and next trigger time point, each with change and clear actions.
  /// Editing stays local until 保存, like the tags it sits next to. 清除
  /// 取消提醒 removes the time point and the rule together — turning off
  /// the recurrence stops the reminder.
  Widget _buildReminderSection() {
    final remindAt = _remindAt;
    final rule = _remindRule;
    return Row(
      key: const Key('reminder_section'),
      children: [
        const Icon(Icons.alarm, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: remindAt == null
              ? Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    TextButton.icon(
                      key: const Key('set_reminder_button'),
                      icon: const Icon(Icons.notification_add, size: 18),
                      label: const Text('设置提醒'),
                      onPressed: _busy ? null : _pickReminder,
                    ),
                    TextButton.icon(
                      key: const Key('set_recurrence_button'),
                      icon: const Icon(Icons.repeat, size: 18),
                      label: const Text('设置循环'),
                      onPressed: _busy ? null : _pickRecurrence,
                    ),
                  ],
                )
              : Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    Text(
                      rule == null
                          ? formatReminder(remindAt)
                          : '${describeRecurrence(rule)} · 下次 ${formatReminder(remindAt)}',
                      key: const Key('reminder_value'),
                    ),
                    TextButton(
                      key: const Key('change_reminder_button'),
                      onPressed:
                          _busy ? null : (rule == null
                              ? _pickReminder
                              : _pickRecurrence),
                      child: const Text('修改'),
                    ),
                    TextButton(
                      key: const Key('clear_reminder_button'),
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _remindAt = null;
                                _remindRule = null;
                              }),
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
  /// set in the past would sit on the memo and silently never fire. The
  /// spec puts no horizon on a reminder; the hundred-year bound only exists
  /// because the picker widget needs a lastDate to build its year grid —
  /// it is a component constraint, not a business rule.
  DateTime get _now => (widget.now ?? DateTime.now)();

  Future<void> _pickReminder() async {
    final now = _now;
    final current = _remindAt;
    final initial = current != null && current.isAfter(now) ? current : now;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now,
      lastDate: now.add(const Duration(days: 100 * 365)),
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
    if (!picked.isAfter(_now)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('提醒时间必须晚于当前时间')));
      return;
    }
    setState(() => _remindAt = picked);
  }

  /// The recurrence picker (T70): one of the preset modes — 每天 / 每周某日 /
  /// 每月某日 / 每年某月某日 — with interval and time of day, no end date.
  /// 保存 computes the first occurrence strictly after now from the rule and
  /// stores it as the reminder's next trigger time point; the scheduler
  /// advances it after every firing.
  Future<void> _pickRecurrence() async {
    final rule = await showDialog<ReminderRule>(
      context: context,
      builder: (_) => _RecurrenceDialog(initial: _remindRule, now: _now),
    );
    if (rule == null || !mounted) return;
    setState(() {
      _remindRule = rule;
      _remindAt = nextOccurrence(rule, _now);
    });
  }

  void _reloadCategories() {
    setState(() => _categories = widget.session.api.categories(widget.session.token));
  }

  int? _defaultCategoryId(List<Category> categories) {
    for (final c in categories) {
      if (c.isBuiltin) return c.id;
    }
    return categories.isEmpty ? null : categories.first.id;
  }
}

String _intervalUnit(ReminderMode mode) => switch (mode) {
      ReminderMode.daily => '天',
      ReminderMode.weekly => '周',
      ReminderMode.monthly => '月',
      ReminderMode.yearly => '年',
    };

/// The recurrence editor dialog (T70). Owns its field state and returns the
/// built [ReminderRule] on 保存, null on 取消 — the caller computes the next
/// occurrence, keeping the dialog purely a rule editor.
class _RecurrenceDialog extends StatefulWidget {
  /// The rule to prefill from; null opens on the defaults (daily, today's
  /// weekday/day/month, the next full hour).
  final ReminderRule? initial;
  final DateTime now;

  const _RecurrenceDialog({required this.initial, required this.now});

  @override
  State<_RecurrenceDialog> createState() => _RecurrenceDialogState();
}

class _RecurrenceDialogState extends State<_RecurrenceDialog> {
  late ReminderMode _mode = widget.initial?.mode ?? ReminderMode.daily;
  late int _weekday = widget.initial?.weekday ?? widget.now.weekday;
  late int _day = widget.initial?.day ?? widget.now.day;
  late int _month = widget.initial?.month ?? widget.now.month;
  late final TextEditingController _interval =
      TextEditingController(text: '${widget.initial?.interval ?? 1}');
  late TimeOfDay _time = widget.initial != null
      ? TimeOfDay(
          hour: widget.initial!.hour, minute: widget.initial!.minute)
      : TimeOfDay.fromDateTime(
          widget.now.add(const Duration(hours: 1)));

  @override
  void dispose() {
    _interval.dispose();
    super.dispose();
  }

  ReminderRule? _buildRule() {
    final parsed = int.tryParse(_interval.text.trim());
    return ReminderRule(
      mode: _mode,
      interval: parsed == null || parsed < 1 ? 1 : parsed,
      weekday: _mode == ReminderMode.weekly ? _weekday : null,
      day: _mode == ReminderMode.monthly || _mode == ReminderMode.yearly
          ? _day
          : null,
      month: _mode == ReminderMode.yearly ? _month : null,
      hour: _time.hour,
      minute: _time.minute,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('recurrence_dialog'),
      title: const Text('循环提醒'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<ReminderMode>(
              key: const Key('recurrence_mode_dropdown'),
              initialValue: _mode,
              decoration: const InputDecoration(labelText: '重复'),
              items: const [
                DropdownMenuItem(value: ReminderMode.daily, child: Text('每天')),
                DropdownMenuItem(value: ReminderMode.weekly, child: Text('每周')),
                DropdownMenuItem(value: ReminderMode.monthly, child: Text('每月')),
                DropdownMenuItem(value: ReminderMode.yearly, child: Text('每年')),
              ],
              onChanged: (value) => setState(() => _mode = value ?? _mode),
            ),
            if (_mode == ReminderMode.weekly)
              DropdownButtonFormField<int>(
                key: const Key('recurrence_weekday_dropdown'),
                initialValue: _weekday,
                decoration: const InputDecoration(labelText: '星期'),
                items: [
                  for (var i = 1; i <= 7; i++)
                    DropdownMenuItem(value: i, child: Text(weekdayName(i))),
                ],
                onChanged: (value) => setState(() => _weekday = value ?? _weekday),
              ),
            if (_mode == ReminderMode.yearly)
              DropdownButtonFormField<int>(
                key: const Key('recurrence_month_dropdown'),
                initialValue: _month,
                decoration: const InputDecoration(labelText: '月'),
                items: [
                  for (var i = 1; i <= 12; i++)
                    DropdownMenuItem(value: i, child: Text('$i 月')),
                ],
                onChanged: (value) => setState(() => _month = value ?? _month),
              ),
            if (_mode == ReminderMode.monthly || _mode == ReminderMode.yearly)
              DropdownButtonFormField<int>(
                key: const Key('recurrence_day_dropdown'),
                initialValue: _day.clamp(1, 31),
                decoration:
                    const InputDecoration(labelText: '日（该月没有这天则顺延到月末）'),
                items: [
                  for (var i = 1; i <= 31; i++)
                    DropdownMenuItem(value: i, child: Text('$i 日')),
                ],
                onChanged: (value) => setState(() => _day = value ?? _day),
              ),
            TextField(
              controller: _interval,
              key: const Key('recurrence_interval_field'),
              decoration: InputDecoration(labelText: '间隔（${_intervalUnit(_mode)}）'),
              keyboardType: TextInputType.number,
            ),
            Row(
              children: [
                const Text('时间'),
                const Spacer(),
                TextButton(
                  key: const Key('recurrence_time_button'),
                  onPressed: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: _time,
                      initialEntryMode: TimePickerEntryMode.input,
                      helpText: '选择提醒时间',
                    );
                    if (picked != null) setState(() => _time = picked);
                  },
                  child:
                      Text('${twoDigits(_time.hour)}:${twoDigits(_time.minute)}'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('recurrence_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('recurrence_save_button'),
          onPressed: () => Navigator.of(context).pop(_buildRule()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
