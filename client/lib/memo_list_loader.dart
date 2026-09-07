import 'dart:async';

import 'api_client.dart';
import 'memo_cache.dart';
import 'memo_filters.dart';
import 'session.dart';

/// One loaded screenful: the user's memos plus the taxonomy names, fetched
/// together so each row can show the category it lives in.
class MemoListData {
  final List<Memo> memos;
  final Map<int, String> categoryNames;

  MemoListData(this.memos, this.categoryNames);
}

/// The memo list's data source (T8, ADR-0003): loads the page the filters
/// ask for and owns the offline read-only state machine. Started offline it
/// serves the cached snapshot and fires [onRetryTick] every few seconds
/// until the server answers again; a load that hits an unreachable server
/// lands in the same offline mode, mid-session or at boot. The server stays
/// the only source of writes — the snapshot is this module's only local
/// state.
class MemoListLoader {
  MemoListLoader({required this.session, required this.cache});

  final MeridianSession session;
  final MemoCache cache;

  /// Fired every few seconds while offline. The screen answers with a load
  /// attempt — its own, so the reminder scheduler (T9) and the fresh
  /// page's way to the top of the screen follow the screen's own paths.
  void Function()? onRetryTick;

  Timer? _retryTimer;

  /// True from the first unreachable load until a retry succeeds.
  bool get offline => _offline;
  bool _offline = false;

  /// The cached snapshot while offline, or null when there is nothing to
  /// show (offline before any full load). Only ever a snapshot that belongs
  /// to this session's own credential — another user's memos are never
  /// shown.
  MemoListData? get cachedData => _cachedData;
  MemoListData? _cachedData;

  /// Loads the page [filters] asks for — tag non-null asks the server for
  /// only the memos carrying it, a memo whose body never mentions the word
  /// still matches (T4); categoryId non-null narrows to one taxonomy
  /// category (T14); query non-null full-text searches title, body, and
  /// tags (T6); all three narrow together. An unfiltered load also
  /// refreshes the offline snapshot — full lists only: a search or filter
  /// result must never masquerade offline as "all my memos". The reconnect
  /// retry lands here too, so recovery also refreshes the cache. An
  /// unreachable server enters offline mode and rethrows: the screen shows
  /// the cache rather than a dead end (ADR-0003).
  Future<MemoListData> load(MemoFilters filters) async {
    try {
      final memos = await session.api.memos(session.token,
          tag: filters.tag, query: filters.query,
          categoryId: filters.category?.id);
      final categories = await session.api.categories(session.token);
      if (!filters.isFiltered) {
        await cache.write(CachedSnapshot(
            token: session.token, memos: memos, categories: categories));
      }
      return MemoListData(memos, {for (final c in categories) c.id: c.name});
    } on ApiException catch (e) {
      if (e.isUnreachable) await goOffline();
      rethrow;
    }
  }

  /// Enters (or re-enters) offline mode: starts the retry poll and reads
  /// the cached snapshot. Idempotent. The flag flips before the first
  /// suspension, so a screen booted offline reads [offline] as true on its
  /// very first build. Returns the snapshot so the screen can keep the
  /// reminder scheduler fed — the reminder notice is local (T9), it fires
  /// from the cache too — or null when nothing cached can be shown.
  Future<MemoListData?> goOffline() async {
    _offline = true;
    _retryTimer ??= Timer.periodic(
        const Duration(seconds: 5), (_) => onRetryTick?.call());
    final snapshot = await cache.read();
    if (snapshot != null && snapshot.token == session.token) {
      _cachedData = MemoListData(
        snapshot.memos,
        {for (final c in snapshot.categories) c.id: c.name},
      );
    }
    return _cachedData;
  }

  /// Back online: stops the retry poll and drops the cached snapshot.
  void backOnline() {
    stopRetrying();
    _offline = false;
    _cachedData = null;
  }

  /// Stops the retry poll without leaving offline mode — the credential
  /// died while offline; the screen signs out instead.
  void stopRetrying() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void dispose() => stopRetrying();
}
