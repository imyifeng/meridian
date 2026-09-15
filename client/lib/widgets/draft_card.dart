import 'package:flutter/material.dart';

import '../api_client.dart';
import '../recurrence.dart';
import '../reminders.dart';
import 'recurrence_dialog.dart';

/// How a draft card's confirmation stands: offered (没问题/有问题 up),
/// questioned (the user said 有问题 — the card stays as context, its fields
/// still adjustable, but it can never be confirmed from this state), or
/// already created (with the way in).
enum DraftStatus { pending, questioned, created }

/// The draft card's editable state — one per draft-carrying chat message,
/// seeded once from the wire draft via [DraftCardModel.fromAgentDraft] and
/// kept current as the user adjusts it. Living here (not in the card
/// widget) is what makes the card survive list rebuilds and off-screen
/// recycling: the message is the state, the card is its view. Tags start
/// empty and grow only by hand — never by the model (the wire's draft has
/// no tags field at all).
class DraftCardModel {
  /// The draft exactly as the wire delivered it — the identity a restored
  /// record is matched against when the 已确认集合 marks it created.
  final AgentDraft source;

  String title;
  String body;
  int? categoryId;
  DateTime? remindAt;
  ReminderRule? remindRule;
  final List<String> tags = [];
  DraftStatus status = DraftStatus.pending;

  /// The memo this card created, as the create response returned it. Set on
  /// the confirming visit; on later visits only [createdMemoId] survives
  /// (the 已确认集合 stores ids), and 打开 re-fetches through it.
  Memo? createdMemo;
  int? createdMemoId;
  bool creating = false;

  bool get confirmed => status == DraftStatus.created;

  /// The one seeding path for a wire draft (the review's convergence): the
  /// live draft frame and a restored display record both land here.
  DraftCardModel.fromAgentDraft(this.source)
      : title = source.title,
        body = source.content,
        categoryId = source.categoryId,
        remindAt = source.remindAt,
        remindRule = source.remindRule;

  /// True when [other] is this card's own wire draft, field for field —
  /// what the post-confirmation refresh matches a record row with.
  bool isSameSource(AgentDraft other) =>
      other.title == source.title &&
      other.content == source.content &&
      other.categoryId == source.categoryId &&
      other.remindAt == source.remindAt &&
      other.remindRule == source.remindRule;
}

/// The category a draft would save under: its wire choice while that choice
/// still exists in the taxonomy, the built-in 未分类 otherwise (and with an
/// empty taxonomy — a failed load — nothing to resolve to). Pure: both the
/// picker's display and the confirm path resolve through this, so the build
/// never writes state.
int? resolveDraftCategoryId(int? categoryId, List<Category> categories) {
  if (categories.any((c) => c.id == categoryId)) return categoryId;
  for (final category in categories) {
    if (category.isBuiltin) return category.id;
  }
  return categories.isEmpty ? null : categories.first.id;
}

/// The draft card (the glossary's Draft): a miniature create form — title,
/// body, category, reminder, and a tag area that starts empty and grows only
/// by the user's hand. 没问题 creates through the ordinary memo API (the
/// screen owns the call) and turns the card into its created state; 有问题
/// keeps the card as conversation context and hands the turn back to the
/// user. Extracted from agent_screen.dart (#76 review) — a mechanical move,
/// the chat page keeps the state machine.
class DraftCard extends StatefulWidget {
  /// The card's editable state, owned by the chat message.
  final DraftCardModel model;

  /// The instance taxonomy (ADR-0002); null until loaded, empty on failure.
  final List<Category>? categories;
  final bool offline;
  final VoidCallback onCategoriesRetry;

  final VoidCallback onConfirm;
  final VoidCallback onQuestion;
  final VoidCallback onOpen;

  /// Structural changes (tags, category, reminder) repaint through the
  /// screen; text edits live in the controllers alone.
  final VoidCallback onChanged;

  const DraftCard({
    super.key,
    required this.model,
    required this.categories,
    required this.offline,
    required this.onCategoriesRetry,
    required this.onConfirm,
    required this.onQuestion,
    required this.onOpen,
    required this.onChanged,
  });

  @override
  State<DraftCard> createState() => _DraftCardState();
}

class _DraftCardState extends State<DraftCard> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  late final TextEditingController _tagField = TextEditingController();

  DraftCardModel get _model => widget.model;

  /// Fields stay adjustable until the card is created; after 有问题 the card
  /// remains as context the user can still tweak — it just can never be
  /// confirmed from that state.
  bool get _editable => !_model.confirmed;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: _model.title);
    _body = TextEditingController(text: _model.body);
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _tagField.dispose();
    super.dispose();
  }

  /// Same rules as the server (T4): trimmed plain text, at most 50 runes,
  /// duplicates collapse. Nothing lands here unless the user typed it.
  void _addTag() {
    final name = _tagField.text.trim();
    if (name.isEmpty) return;
    if (name.runes.length > 50) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('标签最多 50 字')));
      return;
    }
    if (!_model.tags.contains(name)) _model.tags.add(name);
    _tagField.clear();
    widget.onChanged();
  }

  /// Date first, then time — a future moment only, same rule as the memo
  /// editor: a reminder set in the past would silently never fire.
  Future<void> _pickReminder() async {
    final now = DateTime.now();
    final current = _model.remindAt;
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
    if (!picked.isAfter(DateTime.now())) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('提醒时间必须晚于当前时间')));
      return;
    }
    setState(() {
      _model.remindAt = picked;
      _model.remindRule = null;
    });
    widget.onChanged();
  }

  /// The recurrence picker (T70), shared with the memo editor; saving
  /// computes the next occurrence as the reminder's trigger time point.
  Future<void> _pickRecurrence() async {
    final now = DateTime.now();
    final rule = await showDialog<ReminderRule>(
      context: context,
      builder: (_) =>
          RecurrenceDialog(initial: _model.remindRule, now: now),
    );
    if (rule == null || !mounted) return;
    setState(() {
      _model.remindRule = rule;
      _model.remindAt = nextOccurrence(rule, now);
    });
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final model = _model;
    final created = model.confirmed;
    final canConfirm = _editable && !model.creating && !widget.offline;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.edit_note, size: 18, color: colors.onSurfaceVariant),
                const SizedBox(width: 6),
                Text('备忘录草稿',
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: colors.onSurfaceVariant)),
                const Spacer(),
                if (created)
                  Row(
                    key: const Key('draft_created_badge'),
                    children: [
                      Icon(Icons.check_circle,
                          size: 16, color: colors.primary),
                      const SizedBox(width: 4),
                      Text('已创建',
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(color: colors.primary)),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('draft_title_field'),
              controller: _title,
              enabled: _editable,
              decoration: const InputDecoration(labelText: '标题'),
              onChanged: (text) => model.title = text,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('draft_body_field'),
              controller: _body,
              enabled: _editable,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(labelText: '正文'),
              onChanged: (text) => model.body = text,
            ),
            const SizedBox(height: 8),
            _categoryPicker(colors),
            const SizedBox(height: 4),
            _reminderSection(),
            const SizedBox(height: 4),
            _tagSection(),
            const SizedBox(height: 12),
            switch (model.status) {
              DraftStatus.pending => Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        key: const Key('draft_confirm_button'),
                        onPressed: canConfirm ? widget.onConfirm : null,
                        child: model.creating
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Text('没问题'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        key: const Key('draft_reject_button'),
                        onPressed:
                            _editable && !model.creating ? widget.onQuestion : null,
                        child: const Text('有问题'),
                      ),
                    ),
                  ],
                ),
              DraftStatus.questioned => Text(
                  '有问题，请在下方继续说明',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              DraftStatus.created => Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        key: const Key('draft_open_button'),
                        onPressed: widget.onOpen,
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('打开'),
                      ),
                    ),
                  ],
                ),
            },
          ],
        ),
      ),
    );
  }

  /// The taxonomy is fixed (ADR-0002): pick among existing categories, never
  /// type a new one. The displayed value resolves through the pure helper —
  /// the model only learns of a change through the user's own pick, and the
  /// confirm path resolves the same way.
  Widget _categoryPicker(ColorScheme colors) {
    final categories = widget.categories;
    if (categories == null) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
            width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (categories.isEmpty) {
      return Row(
        children: [
          Text('分类加载失败',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant)),
          TextButton(
            key: const Key('draft_category_retry_button'),
            onPressed: widget.onCategoriesRetry,
            child: const Text('重试'),
          ),
        ],
      );
    }
    return DropdownButtonFormField<int>(
      key: const Key('draft_category_dropdown'),
      initialValue: resolveDraftCategoryId(_model.categoryId, categories),
      decoration: const InputDecoration(labelText: '分类'),
      items: [
        for (final category in categories)
          DropdownMenuItem(value: category.id, child: Text(category.name)),
      ],
      onChanged: _editable
          ? (value) {
              _model.categoryId = value;
              widget.onChanged();
            }
          : null,
    );
  }

  /// The reminder (T9/T70) exactly as the memo editor edits it: one-shot
  /// time point or a recurring rule, cleared together.
  Widget _reminderSection() {
    final remindAt = _model.remindAt;
    final rule = _model.remindRule;
    return Row(
      key: const Key('draft_reminder_section'),
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
                      key: const Key('draft_set_reminder_button'),
                      icon: const Icon(Icons.notification_add, size: 18),
                      label: const Text('设置提醒'),
                      onPressed: _editable ? _pickReminder : null,
                    ),
                    TextButton.icon(
                      key: const Key('draft_set_recurrence_button'),
                      icon: const Icon(Icons.repeat, size: 18),
                      label: const Text('设置循环'),
                      onPressed: _editable ? _pickRecurrence : null,
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
                      key: const Key('draft_reminder_value'),
                    ),
                    TextButton(
                      key: const Key('draft_change_reminder_button'),
                      onPressed: !_editable
                          ? null
                          : (rule == null ? _pickReminder : _pickRecurrence),
                      child: const Text('修改'),
                    ),
                    TextButton(
                      key: const Key('draft_clear_reminder_button'),
                      onPressed: !_editable
                          ? null
                          : () {
                              setState(() {
                                _model.remindAt = null;
                                _model.remindRule = null;
                              });
                              widget.onChanged();
                            },
                      child: const Text('取消提醒'),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  /// Tags, all manual (T4): chips for what this draft will carry, an input
  /// to add more. The card never shows nor accepts a model-proposed tag —
  /// there is no such thing on the wire, and no suggestions here either.
  Widget _tagSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('draft_tag_field'),
                controller: _tagField,
                enabled: _editable,
                decoration: const InputDecoration(
                    labelText: '标签', hintText: '输入后添加，仅限手动'),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _addTag(),
              ),
            ),
            IconButton(
              key: const Key('draft_add_tag_button'),
              tooltip: '添加标签',
              icon: const Icon(Icons.add),
              onPressed: _editable ? _addTag : null,
            ),
          ],
        ),
        if (_model.tags.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final tag in _model.tags)
                InputChip(
                  key: Key('draft_tag_chip_$tag'),
                  label: Text(tag),
                  onDeleted: _editable
                      ? () {
                          _model.tags.remove(tag);
                          widget.onChanged();
                        }
                      : null,
                ),
            ],
          ),
      ],
    );
  }
}
