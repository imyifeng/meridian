import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../memo_cache.dart';
import '../reminders.dart';
import 'memo_edit_screen.dart';
import 'memo_view_screen.dart';
import 'trash_screen.dart';

/// The memo list: every memo of the signed-in user, newest first, each with
/// its taxonomy category (ADR-0002). Started offline (T8) it shows the
/// cached snapshot read-only and keeps retrying until the server answers
/// again; the server stays the only source of writes. It also drives
/// reminder scheduling (T9): every full load and the offline snapshot feed
/// the ReminderService, whose local notifications open back into this
/// screen.
class MemosScreen extends StatefulWidget {
  final MeridianApi api;
  final String token;
  final MemoCache cache;

  /// Booted without a reachable server on a cached snapshot: read-only
  /// until a retry succeeds.
  final bool initialOffline;

  /// The platform notification surface (T9); tests inject a fake. Null
  /// means no reminder scheduling at all.
  final ReminderNotifications? reminderNotifications;

  /// Clock override for reminder tests; production uses the wall clock.
  final DateTime Function()? reminderNow;

  final VoidCallback onSignOut;

  const MemosScreen({
    super.key,
    required this.api,
    required this.token,
    required this.cache,
    this.initialOffline = false,
    this.reminderNotifications,
    this.reminderNow,
    required this.onSignOut,
  });

  @override
  State<MemosScreen> createState() => _MemosScreenState();
}

class _MemosScreenState extends State<MemosScreen> {
  late Future<MemoListData> _future;
  String? _filterTag;
  // 全文搜索 (T6)：_searching toggles the app-bar search field,
  // _searchQuery holds the committed query (null = not searching).
  bool _searching = false;
  String? _searchQuery;
  final _searchController = TextEditingController();
  // Offline read-only mode (T8).
  bool _offline = false;
  MemoListData? _cachedData;
  Timer? _retryTimer;
  bool _checkingConnection = false;
  // Reminder scheduling (T9); lives as long as the signed-in list screen.
  ReminderService? _reminders;
  // Quiet mid-session pull feeding the scheduler (T9).
  Timer? _reminderPoll;

  // Every `_future = _load()` carries `..ignore()`: load errors must be
  // handled even when the FutureBuilder never subscribes because the load
  // flipped the screen offline before the next frame.
  @override
  void initState() {
    super.initState();
    final notifications = widget.reminderNotifications;
    if (notifications != null) {
      // The service outlives nothing but this screen: disposing with it
      // also drops the in-memory armed set, so a fresh run never refires
      // what it did not see come due.
      final service = ReminderService(
          notifications: notifications, now: widget.reminderNow);
      service.onOpen = _openMemo;
      _reminders = service;
      service.start();
      // ADR-0004 bans server push, not client fetch: while this client
      // runs, reminders set or changed on another device reach the
      // scheduler without waiting for the user to navigate.
      _reminderPoll = Timer.periodic(
          ReminderService.tickInterval * 2, (_) => _pollReminders());
    }
    if (widget.initialOffline) {
      _offline = true;
      _goOffline();
    } else {
      _future = _load()..ignore();
    }
  }

  @override
  void dispose() {
    _reminders?.dispose();
    _reminderPoll?.cancel();
    _retryTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// One quiet poll tick: pull the full list and hand it to the scheduler,
  /// without disturbing whatever the screen is showing. Full lists only and
  /// online only — offline, the reconnect loop's successful _load syncs;
  /// filtered, the page is not the whole truth.
  Future<void> _pollReminders() async {
    if (_offline || _filterTag != null || _searchQuery != null) return;
    try {
      final memos = await widget.api.memos(widget.token);
      await _reminders?.sync(memos);
    } on ApiException catch (e) {
      if (e.isUnauthorized && mounted) widget.onSignOut();
      // Unreachable: the next tick or the reconnect loop handles it.
    }
  }

  /// Enters (or re-enters) offline read-only mode: poll for the connection
  /// and render the cached snapshot. Idempotent — any load that hits an
  /// unreachable server lands here, mid-session or at boot.
  Future<void> _goOffline() async {
    _retryTimer ??=
        Timer.periodic(const Duration(seconds: 5), (_) => _tryReconnect());
    final snapshot = await widget.cache.read();
    if (!mounted) return;
    setState(() {
      _offline = true;
      if (snapshot != null && snapshot.token == widget.token) {
        _cachedData = MemoListData(
          snapshot.memos,
          {for (final c in snapshot.categories) c.id: c.name},
        );
      }
    });
    // The reminder notice is local (T9): it fires from the cache too.
    final data = _cachedData;
    if (data != null) await _reminders?.sync(data.memos);
  }

  Future<MemoListData> _load() async {
    // tag non-null asks the server for only the memos carrying it — a memo
    // whose body never mentions the word still matches (T4). query non-null
    // full-text searches title, body, and tags (T6); both narrow together.
    try {
      final memos = await widget.api
          .memos(widget.token, tag: _filterTag, query: _searchQuery);
      final categories = await widget.api.categories(widget.token);
      // Keep the offline snapshot current (T8) — full lists only: a search
      // or filter result must never masquerade offline as "all my memos".
      // The reconnect retry lands here too, so recovery also refreshes the
      // cache. Same rule for the scheduler (T9): a filtered page must not
      // disarm reminders it does not show.
      if (_filterTag == null && _searchQuery == null) {
        await widget.cache.write(CachedSnapshot(
            token: widget.token, memos: memos, categories: categories));
        await _reminders?.sync(memos);
      }
      return MemoListData(memos, {for (final c in categories) c.id: c.name});
    } on ApiException catch (e) {
      // The server vanished out from under a live screen: go read-only on
      // the cache rather than showing a dead end (ADR-0003).
      if (e.isUnreachable) await _goOffline();
      rethrow;
    }
  }

  /// One retry tick: the moment the server answers, the screen goes back to
  /// its normal live behavior, already showing fresh data.
  Future<void> _tryReconnect() async {
    if (_checkingConnection) return;
    _checkingConnection = true;
    try {
      final data = await _load();
      if (!mounted) return;
      _retryTimer?.cancel();
      _retryTimer = null;
      setState(() {
        _offline = false;
        _cachedData = null;
        _future = Future.value(data);
      });
    } on ApiException catch (e) {
      if (e.isUnauthorized && mounted) {
        // The credential died while we were offline; now that the server
        // can finally say so, sign out like any other dead session.
        _retryTimer?.cancel();
        _retryTimer = null;
        widget.onSignOut();
      }
      // Still unreachable: stay read-only until the next tick.
    } finally {
      _checkingConnection = false;
    }
  }

  void _reload() {
    setState(() {
      _future = _load()..ignore();
    });
  }

  /// Offers the user's own tag history (T4); picking one filters the list.
  Future<void> _pickFilter() async {
    List<String> tags;
    try {
      tags = await widget.api.tags(widget.token);
    } on ApiException {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('加载标签失败')));
      }
      return;
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: tags.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('还没有用过的标签'),
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final t in tags)
                      ListTile(
                        key: Key('filter_tag_$t'),
                        leading: const Icon(Icons.label_outline),
                        title: Text(t),
                        onTap: () => Navigator.of(context).pop(t),
                      ),
                  ],
                ),
              ),
      ),
    );
    if (picked == null) return;
    setState(() {
      _filterTag = picked;
      _future = _load()..ignore();
    });
  }

  void _clearFilter() {
    setState(() {
      _filterTag = null;
      _future = _load()..ignore();
    });
  }

  void _openSearch() {
    setState(() {
      _searching = true;
    });
  }

  /// Commits the search field's text; a blank query just shows everything.
  void _runSearch(String term) {
    final q = term.trim();
    setState(() {
      _searchQuery = q.isEmpty ? null : q;
      _future = _load()..ignore();
    });
  }

  /// Leaves search mode and restores the full list.
  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searching = false;
      _searchQuery = null;
      _future = _load()..ignore();
    });
  }

  Future<void> _openEditor([Memo? memo]) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MemoEditScreen(api: widget.api, token: widget.token, memo: memo),
    ));
    _reload();
  }

  /// Offline (T8): cached memos open as pure readers — no editor, no server.
  Future<void> _openReadOnlyViewer(Memo memo) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MemoViewScreen(memo: memo),
    ));
  }

  /// Opens a memo: editor online, reader offline (T8). One path for the
  /// list rows and the reminder notifications alike.
  Future<void> _openMemo(Memo memo) async {
    if (_offline) {
      await _openReadOnlyViewer(memo);
    } else {
      await _openEditor(memo);
    }
  }

  /// The recycle bin (T5); anything may have come back out of it.
  Future<void> _openTrash() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TrashScreen(api: widget.api, token: widget.token),
    ));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                key: const Key('search_field'),
                controller: _searchController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: '搜索标题、正文、标签',
                  border: InputBorder.none,
                ),
                onSubmitted: _runSearch,
              )
            : Text(_filterTag == null ? 'Meridian' : '标签：$_filterTag'),
        actions: [
          if (_searching)
            IconButton(
              key: const Key('clear_search_button'),
              icon: const Icon(Icons.close),
              tooltip: '退出搜索',
              onPressed: _clearSearch,
            )
          else
            IconButton(
              key: const Key('search_button'),
              icon: const Icon(Icons.search),
              tooltip: '搜索',
              // Search runs on the server; offline there is only the cache.
              onPressed: _offline ? null : _openSearch,
            ),
          if (_filterTag != null)
            IconButton(
              key: const Key('clear_filter_button'),
              icon: const Icon(Icons.close),
              tooltip: '清除筛选',
              onPressed: _clearFilter,
            ),
          IconButton(
            key: const Key('filter_button'),
            icon: const Icon(Icons.filter_list),
            tooltip: '按标签筛选',
            onPressed: _offline ? null : _pickFilter,
          ),
          IconButton(
            key: const Key('trash_button'),
            icon: const Icon(Icons.delete_outline),
            tooltip: '回收站',
            // The recycle bin is server data, and its actions are writes.
            onPressed: _offline ? null : _openTrash,
          ),
          IconButton(icon: const Icon(Icons.logout), tooltip: '退出登录', onPressed: widget.onSignOut),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('new_memo_button'),
        tooltip: _offline ? '离线中，暂不可新建' : '新建备忘录',
        onPressed: _offline ? null : _openEditor,
        child: const Icon(Icons.add),
      ),
      body: _offline ? _offlineBody() : FutureBuilder<MemoListData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('加载备忘录失败'),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _reload, child: const Text('重试')),
                ],
              ),
            );
          }
          return _memoList(snapshot.data ??
              MemoListData(const <Memo>[], const {}));
        },
      ),
    );
  }

  /// The offline read-only list (T8): the cached snapshot under a banner
  /// that says so, with every server-backed entry point disabled. No
  /// snapshot (offline before any full load) shows empty, not an error.
  Widget _offlineBody() {
    final data = _cachedData;
    if (data == null) {
      return Column(
        children: [
          _offlineBanner(),
          const Expanded(child: Center(child: Text('暂无可离线查看的内容'))),
        ],
      );
    }
    return Column(
      children: [
        _offlineBanner(),
        Expanded(child: _memoList(data)),
      ],
    );
  }

  Widget _offlineBanner() {
    return Material(
      key: const Key('offline_banner'),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.wifi_off, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '离线模式：仅可查看已缓存的内容，恢复联网后自动更新',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _memoList(MemoListData data) {
    final memos = data.memos;
    final categoryNames = data.categoryNames;
    if (memos.isEmpty) {
      final message = _searchQuery != null
          ? '未找到匹配的备忘录'
          : _filterTag == null
              ? '暂无备忘录'
              : '该标签下暂无备忘录';
      return Center(child: Text(message));
    }
    return ListView.builder(
      key: const Key('memo_list'),
      itemCount: memos.length,
      itemBuilder: (context, i) {
        final memo = memos[i];
        return ListTile(
          title: Text(memo.title),
          subtitle: memo.body.isEmpty ? null : Text(memo.body, maxLines: 1, overflow: TextOverflow.ellipsis),
          // The alarm marks a memo carrying a reminder (T9) — one set on any
          // device shows up here, because it rode along with the memo.
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (memo.remindAt != null) ...[
              const Icon(Icons.alarm, size: 16),
              const SizedBox(width: 6),
            ],
            Text(categoryNames[memo.categoryId] ?? ''),
          ]),
          onTap: () => _openMemo(memo),
        );
      },
    );
  }}

/// One loaded screenful: the user's memos plus the taxonomy names, fetched
/// together so each row can show the category it lives in.
class MemoListData {
  final List<Memo> memos;
  final Map<int, String> categoryNames;

  MemoListData(this.memos, this.categoryNames);
}
