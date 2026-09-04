import 'dart:async';

import 'api_client.dart';

/// How every surface that shows a reminder formats it (editor, viewer,
/// notification body).
String formatReminder(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// Port to the platform's local notification surface (Windows toast /
/// Android notification). Production wraps flutter_local_notifications; UI
/// seam tests inject a recording fake — the injected fake is where the
/// scheduling decisions are verified, the real popups being a manual
/// verification item (spec: 提醒调度).
abstract class ReminderNotifications {
  /// One-time setup: asks for the OS permission where the platform needs
  /// one, and registers [onTap] — fired with the payload memo id when the
  /// user taps a reminder notification.
  Future<void> init({required void Function(int memoId) onTap});

  /// Shows the due-reminder notification for [memo]: the memo's title in
  /// the notice, its id as the tap payload.
  Future<void> showDueReminder(Memo memo);
}

/// Decides when a reminder becomes a notification (T9, ADR-0004). The
/// reminder lives on the memo and syncs with it, but firing is strictly
/// local: a client notifies only while it runs — no server push, no
/// background keep-alive, and a reminder that was already past when this
/// run first saw it stays quiet instead of popping stale notices on every
/// start. What fires is the transition this client observed: seen as a
/// future time, then come due.
class ReminderService {
  ReminderService({
    required ReminderNotifications notifications,
    DateTime Function()? now,
    this.tickInterval = const Duration(seconds: 15),
  })  : _surface = notifications,
        _now = now ?? DateTime.now;

  /// Called when the user taps a reminder notification; [memo] is the memo
  /// the notice was about. Set by whoever can open it — the memo list
  /// screen.
  void Function(Memo memo)? onOpen;

  final ReminderNotifications _surface;
  final DateTime Function() _now;

  /// How often the running app checks whether a reminder came due; the
  /// notice is never earlier than the due time, at most one tick late.
  final Duration tickInterval;

  Timer? _ticker;
  bool _started = false;

  /// The reminders armed this run: memo id -> the remindAt they were armed
  /// with. Firing removes an entry, so it happens exactly once; a memo
  /// whose reminder changes disarms and — if still future — re-arms.
  final Map<int, DateTime> _armed = {};
  Map<int, Memo> _latest = const {};

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _surface.init(onTap: _handleTap);
    _ticker = Timer.periodic(tickInterval, (_) => _fireDue());
  }

  void _handleTap(int memoId) {
    final memo = _latest[memoId];
    if (memo != null) onOpen?.call(memo);
  }

  /// Feeds the service the user's full live memo list — full only: a
  /// filtered or searched page must never disarm reminders it happens not
  /// to show. Full loads feed it online, the offline snapshot feeds it
  /// offline: the notification is local, so reminders fire either way.
  Future<void> sync(List<Memo> memos) async {
    _latest = {for (final m in memos) m.id: m};
    final desired = {
      for (final m in memos)
        if (m.remindAt != null) m.id: m.remindAt!,
    };
    _armed.removeWhere((id, at) => desired[id] != at);
    for (final entry in desired.entries) {
      if (!_armed.containsKey(entry.key) && entry.value.isAfter(_now())) {
        _armed[entry.key] = entry.value;
      }
    }
    _fireDue();
  }

  void _fireDue() {
    final now = _now();
    final due = [
      for (final entry in _armed.entries)
        if (!entry.value.isAfter(now)) entry.key,
    ];
    for (final id in due) {
      _armed.remove(id);
      final memo = _latest[id];
      if (memo != null) {
        // One late notice must not stall the tick loop.
        _surface.showDueReminder(memo).catchError((_) {});
      }
    }
  }

  void dispose() {
    _ticker?.cancel();
  }
}
