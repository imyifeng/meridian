import 'package:flutter/material.dart';

import '../recurrence.dart';

String _intervalUnit(ReminderMode mode) => switch (mode) {
      ReminderMode.daily => '天',
      ReminderMode.weekly => '周',
      ReminderMode.monthly => '月',
      ReminderMode.yearly => '年',
    };

/// The recurrence editor dialog (T70) — one of the preset modes — 每天 /
/// 每周某日 / 每月某日 / 每年某月某日 — with interval and time of day, no
/// end date. Owns its field state and returns the built [ReminderRule] on
/// 保存, null on 取消; the caller computes the next occurrence, keeping the
/// dialog purely a rule editor. Shared by the memo editor and the 智能体's
/// draft card (#76), which set reminders the same way.
class RecurrenceDialog extends StatefulWidget {
  /// The rule to prefill from; null opens on the defaults (daily, today's
  /// weekday/day/month, the next full hour).
  final ReminderRule? initial;
  final DateTime now;

  const RecurrenceDialog({super.key, required this.initial, required this.now});

  @override
  State<RecurrenceDialog> createState() => _RecurrenceDialogState();
}

class _RecurrenceDialogState extends State<RecurrenceDialog> {
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
