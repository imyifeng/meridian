import 'dart:async';

import 'api_client.dart';
import 'reminders.dart';

/// Keeps the reminder scheduler (T9, ADR-0004) fed while the memo list is
/// up: starts the service against the platform notification surface, hands
/// it every full memo list, and — while the client runs — quietly pulls the
/// full list on a fixed cadence, so reminders set or changed on another
/// device reach the scheduler without waiting for the user to navigate.
/// It outlives nothing but its screen: disposing with it also drops the
/// in-memory armed set, so a fresh run never refires what it did not see
/// come due.
class ReminderSync {
  ReminderSync({
    required ReminderNotifications notifications,
    required this.fetchMemos,
    required this.mayPoll,
    required this.onUnauthorized,
    DateTime Function()? now,
  }) : _service = ReminderService(notifications: notifications, now: now);

  /// The full live list, for the quiet poll.
  final Future<List<Memo>> Function() fetchMemos;

  /// Whether a poll may run right now. Full lists only and online only —
  /// offline, the reconnect loop's successful load syncs; filtered, the
  /// page is not the whole truth.
  final bool Function() mayPoll;

  /// The credential died; the screen signs out like any other dead session.
  final void Function() onUnauthorized;

  /// A reminder notification tapped: open the memo it was about.
  set onOpen(void Function(Memo memo)? open) => _service.onOpen = open;

  final ReminderService _service;
  Timer? _poll;

  /// One-time notification setup, then the quiet poll at twice the
  /// scheduler's tick. ADR-0004 bans server push, not client fetch.
  void start() {
    _service.start();
    _poll = Timer.periodic(ReminderService.tickInterval * 2, (_) => poll());
  }

  /// Feeds the scheduler a full list — full only: a filtered or searched
  /// page must never disarm reminders it happens not to show.
  Future<void> sync(List<Memo> memos) => _service.sync(memos);

  /// One quiet poll tick: pull the full list and hand it to the scheduler,
  /// without disturbing whatever the screen is showing.
  Future<void> poll() async {
    if (!mayPoll()) return;
    try {
      await sync(await fetchMemos());
    } on ApiException catch (e) {
      if (e.isUnauthorized) onUnauthorized();
      // Unreachable: the next tick or the reconnect loop handles it.
    }
  }

  void dispose() {
    _poll?.cancel();
    _service.dispose();
  }
}
