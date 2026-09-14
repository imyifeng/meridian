import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/recurrence.dart';

ReminderRule rule(ReminderMode mode,
    {int interval = 1,
    int? weekday,
    int? day,
    int? month,
    int hour = 8,
    int minute = 30}) {
  return ReminderRule(
    mode: mode,
    interval: interval,
    weekday: weekday,
    day: day,
    month: month,
    hour: hour,
    minute: minute,
  );
}

void main() {
  group('nextOccurrence：严格晚于 after 的下一个触发点', () {
    test('每天：当日时分已过则顺延到明天', () {
      // 2026-01-05 是周一。
      final next = nextOccurrence(rule(ReminderMode.daily),
          DateTime(2026, 1, 5, 10));
      expect(next, DateTime(2026, 1, 6, 8, 30));
    });

    test('每天：当日时分未到则就在当天', () {
      final next = nextOccurrence(
          rule(ReminderMode.daily, hour: 14, minute: 0),
          DateTime(2026, 1, 5, 10));
      expect(next, DateTime(2026, 1, 5, 14, 0));
    });

    test('每天：恰好等于触发点不算，取下一个', () {
      final next = nextOccurrence(rule(ReminderMode.daily),
          DateTime(2026, 1, 5, 8, 30));
      expect(next, DateTime(2026, 1, 6, 8, 30));
    });

    test('每 3 天：按间隔跨过已过的候选', () {
      final next = nextOccurrence(rule(ReminderMode.daily, interval: 3),
          DateTime(2026, 1, 5, 10));
      // 1 月 5 日 08:30 已过，跨 3 天到 1 月 8 日。
      expect(next, DateTime(2026, 1, 8, 8, 30));
    });

    test('每周：取本周内下一个匹配星期几', () {
      final next = nextOccurrence(rule(ReminderMode.weekly, weekday: 3),
          DateTime(2026, 1, 5, 10)); // 周一 → 周三
      expect(next, DateTime(2026, 1, 7, 8, 30));
    });

    test('每周：当天已过触发点则跳到下周同日', () {
      final next = nextOccurrence(rule(ReminderMode.weekly, weekday: 3),
          DateTime(2026, 1, 7, 9)); // 周三 09:00 已过 08:30
      expect(next, DateTime(2026, 1, 14, 8, 30));
    });

    test('每 2 周：从匹配日起按 7 天 × 间隔跨步', () {
      final next = nextOccurrence(
          rule(ReminderMode.weekly, weekday: 3, interval: 2),
          DateTime(2026, 1, 7, 9));
      expect(next, DateTime(2026, 1, 21, 8, 30));
    });

    test('每月：当月该日未过则取当月', () {
      final next = nextOccurrence(rule(ReminderMode.monthly, day: 15),
          DateTime(2026, 1, 5, 10));
      expect(next, DateTime(2026, 1, 15, 8, 30));
    });

    test('每月：该日已过则取下月，跨年也成立', () {
      final next = nextOccurrence(rule(ReminderMode.monthly, day: 15),
          DateTime(2026, 12, 15, 9));
      expect(next, DateTime(2027, 1, 15, 8, 30));
    });

    test('每月 31 日：目标月没有该日则顺延到月末', () {
      // 1 月 31 日 08:30 已过 → 2 月没有 31 日，取 2 月最后一天（28 日）。
      final next = nextOccurrence(rule(ReminderMode.monthly, day: 31),
          DateTime(2026, 1, 31, 9));
      expect(next, DateTime(2026, 2, 28, 8, 30));
    });

    test('每月 31 日：月末顺延不产生漂移，下个月回到 31 日', () {
      final next = nextOccurrence(rule(ReminderMode.monthly, day: 31),
          DateTime(2026, 2, 28, 9));
      expect(next, DateTime(2026, 3, 31, 8, 30));
    });

    test('每年：取今年该月该日，已过则取明年', () {
      final next =
          nextOccurrence(rule(ReminderMode.yearly, month: 3, day: 15),
              DateTime(2026, 1, 5, 10));
      expect(next, DateTime(2026, 3, 15, 8, 30));

      final nextYear =
          nextOccurrence(rule(ReminderMode.yearly, month: 3, day: 15),
              DateTime(2026, 3, 15, 9));
      expect(nextYear, DateTime(2027, 3, 15, 8, 30));
    });

    test('每年 2 月 29 日：平年取 2 月 28 日，闰年取 29 日', () {
      final flat =
          nextOccurrence(rule(ReminderMode.yearly, month: 2, day: 29),
              DateTime(2026, 3, 1, 9));
      expect(flat, DateTime(2027, 2, 28, 8, 30));

      final leap =
          nextOccurrence(rule(ReminderMode.yearly, month: 2, day: 29),
              DateTime(2028, 1, 1, 9));
      expect(leap, DateTime(2028, 2, 29, 8, 30));
    });

    test('每 2 年：间隔按年跨步', () {
      final next = nextOccurrence(
          rule(ReminderMode.yearly, month: 3, day: 15, interval: 2),
          DateTime(2026, 3, 15, 9));
      expect(next, DateTime(2028, 3, 15, 8, 30));
    });
  });

  group('describeRecurrence：循环规则的界面文案', () {
    test('各预设模式与间隔', () {
      expect(describeRecurrence(rule(ReminderMode.daily)), '每天 08:30');
      expect(describeRecurrence(rule(ReminderMode.daily, interval: 3)),
          '每 3 天 08:30');
      expect(describeRecurrence(rule(ReminderMode.weekly, weekday: 3)),
          '每周三 08:30');
      expect(describeRecurrence(
              rule(ReminderMode.weekly, weekday: 3, interval: 2)),
          '每 2 周的周三 08:30');
      expect(describeRecurrence(rule(ReminderMode.monthly, day: 15)),
          '每月 15 日 08:30');
      expect(describeRecurrence(
              rule(ReminderMode.monthly, day: 15, interval: 2)),
          '每 2 个月的 15 日 08:30');
      expect(describeRecurrence(rule(ReminderMode.yearly, month: 3, day: 15)),
          '每年 3 月 15 日 08:30');
      expect(describeRecurrence(
              rule(ReminderMode.yearly, month: 3, day: 15, interval: 2)),
          '每 2 年的 3 月 15 日 08:30');
    });
  });

  test('ReminderRule 与 wire JSON 往返：模式不带的字段不出现在线上', () {
    const r = ReminderRule(
        mode: ReminderMode.weekly,
        interval: 2,
        weekday: 3,
        hour: 8,
        minute: 30);
    expect(r.toJson(), {
      'mode': 'weekly',
      'interval': 2,
      'weekday': 3,
      'hour': 8,
      'minute': 30,
    });
    expect(ReminderRule.fromJson(r.toJson()), r);
  });
}
