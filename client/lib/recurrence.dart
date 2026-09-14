/// The recurrence rule of a repeating reminder (T70): preset pattern plus
/// interval plus time of day, no end date. Deliberately structured — never
/// an RRULE string. This is the one place that knows both the wire shape
/// (shared with the Go server's validation) and the local-time math that
/// derives the next trigger time point from a rule (ADR-0004: scheduling
/// is the client's job, the instance just stores and serves the rule).
library;

/// The preset recurrence patterns.
enum ReminderMode {
  /// Every [ReminderRule.interval] days.
  daily,

  /// Every [ReminderRule.interval] weeks, on [ReminderRule.weekday].
  weekly,

  /// Every [ReminderRule.interval] months, on [ReminderRule.day].
  monthly,

  /// Every [ReminderRule.interval] years, on [ReminderRule.month]
  /// [ReminderRule.day].
  yearly,
}

/// One preset recurrence pattern with interval and time of day.
class ReminderRule {
  final ReminderMode mode;

  /// How many of the mode's unit pass between occurrences; at least 1.
  final int interval;

  /// The weekday mode's day: 1=周一 … 7=周日 (DateTime.weekday's numbering).
  /// Meaningless in the other modes; null there.
  final int? weekday;

  /// The day of the month for the monthly and yearly modes, 1..31. A month
  /// without that day fires on the month's last day instead.
  final int? day;

  /// The yearly mode's month, 1..12. Meaningless in the other modes; null
  /// there.
  final int? month;

  /// The local time of day every occurrence fires at.
  final int hour;
  final int minute;

  const ReminderRule({
    required this.mode,
    this.interval = 1,
    this.weekday,
    this.day,
    this.month,
    required this.hour,
    required this.minute,
  });

  /// The API wire shape, also what the instance stores. Fields a mode does
  /// not take are omitted, so the JSON is exactly the server's validated
  /// shape.
  Map<String, dynamic> toJson() => {
        'mode': _modeNames[mode]!,
        'interval': interval,
        if (weekday != null) 'weekday': weekday,
        if (day != null) 'day': day,
        if (month != null) 'month': month,
        'hour': hour,
        'minute': minute,
      };

  /// Decodes the wire shape the server serves back.
  static ReminderRule fromJson(Map<String, dynamic> json) {
    final mode = _modeNames.entries
        .firstWhere((e) => e.value == json['mode'])
        .key;
    return ReminderRule(
      mode: mode,
      interval: json['interval'] as int? ?? 1,
      weekday: json['weekday'] as int?,
      day: json['day'] as int?,
      month: json['month'] as int?,
      hour: json['hour'] as int,
      minute: json['minute'] as int,
    );
  }

  /// Equality matters for scheduler bookkeeping: a memo whose rule changed
  /// must not be mistaken for one whose rule stayed put.
  @override
  bool operator ==(Object other) =>
      other is ReminderRule &&
      other.mode == mode &&
      other.interval == interval &&
      other.weekday == weekday &&
      other.day == day &&
      other.month == month &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(mode, interval, weekday, day, month, hour,
      minute);
}

const _modeNames = {
  ReminderMode.daily: 'daily',
  ReminderMode.weekly: 'weekly',
  ReminderMode.monthly: 'monthly',
  ReminderMode.yearly: 'yearly',
};

/// The first occurrence of [rule] strictly after [after], in local time.
/// Every occurrence sits on the rule's time of day; a month without the
/// rule's day (the 31st in February) runs to that month's last day, and the
/// stepping always recomputes from the calendar — a clamped February never
/// drags March off its own 31st.
DateTime nextOccurrence(ReminderRule rule, DateTime after) {
  DateTime at(int year, int month, int day) =>
      DateTime(year, month, day, rule.hour, rule.minute);
  switch (rule.mode) {
    case ReminderMode.daily:
      var d = DateTime(after.year, after.month, after.day);
      for (;;) {
        final c = at(d.year, d.month, d.day);
        if (c.isAfter(after)) return c;
        d = DateTime(d.year, d.month, d.day + rule.interval);
      }
    case ReminderMode.weekly:
      // From after's date to the first matching weekday, then in steps of
      // interval weeks; the first candidate past [after] wins. Dart's % is
      // non-negative, so the shift lands in 0..6 with no correction.
      final shift = (rule.weekday! - after.weekday) % 7;
      final first =
          DateTime(after.year, after.month, after.day + shift);
      for (var k = 0;; k++) {
        final c = at(first.year, first.month, first.day + 7 * rule.interval * k);
        if (c.isAfter(after)) return c;
      }
    case ReminderMode.monthly:
      // Months as one absolute count so a short month's clamp never drifts
      // into the next rule step.
      final m0 = after.year * 12 + after.month - 1;
      for (var k = 0;; k++) {
        final m = m0 + rule.interval * k;
        final year = m ~/ 12;
        final month = m % 12 + 1;
        final c = at(year, month, rule.day!.clamp(1, _daysInMonth(year, month)));
        if (c.isAfter(after)) return c;
      }
    case ReminderMode.yearly:
      for (var k = 0;; k++) {
        final year = after.year + rule.interval * k;
        final c =
            at(year, rule.month!, rule.day!.clamp(1, _daysInMonth(year, rule.month!)));
        if (c.isAfter(after)) return c;
      }
  }
}

int _daysInMonth(int year, int month) {
  // Day 0 of the following month is the month's last day.
  return month == 12
      ? DateTime(year + 1, 1, 0).day
      : DateTime(year, month + 1, 0).day;
}

/// Zero-pads to two digits — how times and dates render everywhere.
String twoDigits(int n) => n.toString().padLeft(2, '0');

/// '周三' — the weekday mode's day as every surface names it; the numbering
/// is DateTime.weekday's, 1=周一 … 7=周日.
String weekdayName(int weekday) => '周${_weekdayNames[weekday]!}';

/// How every surface that shows a recurring reminder names its rule
/// (editor, viewer), e.g. '每 2 周的周三 08:30'.
String describeRecurrence(ReminderRule rule) {
  final time = '${twoDigits(rule.hour)}:${twoDigits(rule.minute)}';
  switch (rule.mode) {
    case ReminderMode.daily:
      return rule.interval == 1 ? '每天 $time' : '每 ${rule.interval} 天 $time';
    case ReminderMode.weekly:
      final day = weekdayName(rule.weekday!);
      return rule.interval == 1
          ? '每$day $time'
          : '每 ${rule.interval} 周的$day $time';
    case ReminderMode.monthly:
      return rule.interval == 1
          ? '每月 ${rule.day} 日 $time'
          : '每 ${rule.interval} 个月的 ${rule.day} 日 $time';
    case ReminderMode.yearly:
      final date = '${rule.month} 月 ${rule.day} 日';
      return rule.interval == 1
          ? '每年 $date $time'
          : '每 ${rule.interval} 年的 $date $time';
  }
}

const _weekdayNames = {
  1: '一',
  2: '二',
  3: '三',
  4: '四',
  5: '五',
  6: '六',
  7: '日',
};
