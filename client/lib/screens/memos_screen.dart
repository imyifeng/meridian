import 'package:flutter/material.dart';

import '../api_client.dart';
import '../editor/meridian_editor.dart';
import '../memo_cache.dart';
import '../memo_filters.dart';
import '../memo_list_loader.dart';
import '../reminders.dart';
import '../reminder_sync.dart';
import '../session.dart';
import 'filter_sheets.dart';
import 'memo_edit_screen.dart';
import 'memo_view_screen.dart';
import 'trash_screen.dart';

/// The memo list UI: every memo of the signed-in user, newest first, each
/// with its taxonomy category (ADR-0002). What feeds it lives in its own
/// modules — [MemoListLoader] for loads and the offline read-only state
/// (T8), [ReminderSync] for keeping the scheduler fed (T9), the filter
/// sheets for picking a tag or category. This screen wires them and draws
/// what they decide: it also opens into the editor, the reader, and the
/// recycle bin, and is where reminder notifications land (T9).
class MemosScreen extends StatefulWidget {
  final MeridianSession session;
  final MemoCache cache;

  /// Booted without a reachable server on a cached snapshot: read-only
  /// until a retry succeeds.
  final bool initialOffline;

  /// The platform notification surface (T9); tests inject a fake. Null
  /// means no reminder scheduling at all.
  final ReminderNotifications? reminderNotifications;

  /// Clock override for reminder tests; production uses the wall clock.
  final DateTime Function()? reminderNow;

  /// False in the Web 简易客户端 (T10): memos open without the reminder
  /// editing entry — there, reminders are a 客户端 feature.
  final bool showReminder;

  final VoidCallback onSignOut;

  const MemosScreen({
    super.key,
    required this.session,
    required this.cache,
    this.initialOffline = false,
    this.reminderNotifications,
    this.reminderNow,
    this.showReminder = true,
    required this.onSignOut,
  });

  @override
  State<MemosScreen> createState() => _MemosScreenState();
}

class _MemosScreenState extends State<MemosScreen> {
  late final MemoListLoader _loader;
  late Future<MemoListData> _future;
  String? _filterTag;
  // 分类筛选 (T14)：picked from the taxonomy sheet; categories are
  // read-only here (ADR-0002) — this only chooses among them.
  Category? _filterCategory;
  // 全文搜索 (T6)：_searching toggles the app-bar search field,
  // _searchQuery holds the committed query (null = not searching).
  bool _searching = false;
  String? _searchQuery;
  final _searchController = TextEditingController();
  // Reminder scheduling (T9); lives as long as the signed-in list screen.
  ReminderSync? _reminders;
  // Serialized reconnect attempts: a tick landing on a still-running load
  // is dropped, so a slow server never piles them up.
  bool _checkingConnection = false;

  /// The narrowing in force, as one bundle: what the load asks the server
  /// for, and what "not the whole truth" means for the snapshot and
  /// scheduler rules.
  MemoFilters get _filters => MemoFilters(
      tag: _filterTag, category: _filterCategory, query: _searchQuery);

  // Every `_future = _load()` carries `..ignore()`: load errors must be
  // handled even when the FutureBuilder never subscribes because the load
  // flipped the screen offline before the next frame.
  @override
  void initState() {
    super.initState();
    _loader = MemoListLoader(session: widget.session, cache: widget.cache)
      ..onRetryTick = _tryReconnect;
    final notifications = widget.reminderNotifications;
    if (notifications != null) {
      _reminders = ReminderSync(
        notifications: notifications,
        fetchMemos: () => widget.session.api.memos(widget.session.token),
        mayPoll: () => !_loader.offline && !_filters.isFiltered,
        onUnauthorized: _signedOut,
        now: widget.reminderNow,
      )..onOpen = _openMemo;
      _reminders!.start();
    }
    if (widget.initialOffline) {
      _goOffline();
    } else {
      _future = _load()..ignore();
    }
  }

  @override
  void dispose() {
    _reminders?.dispose();
    _loader.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _signedOut() {
    if (mounted) widget.onSignOut();
  }

  /// One full load: the loader fetches the page and keeps the offline
  /// snapshot current on the same full-truth rule, and a full page also
  /// feeds the scheduler (T9) — a filtered page must not disarm reminders
  /// it does not show. A server that vanished out from under a live screen
  /// puts the loader into offline mode; the screen follows suit — the
  /// cached snapshot becomes the page and keeps feeding the scheduler —
  /// rather than showing a dead end (ADR-0003).
  Future<MemoListData> _load() async {
    try {
      final data = await _loader.load(_filters);
      if (!_filters.isFiltered) await _reminders?.sync(data.memos);
      return data;
    } on ApiException catch (e) {
      if (e.isUnreachable) await _goOffline();
      rethrow;
    }
  }

  /// Enters offline read-only mode (T8) with the loader and renders the
  /// cached snapshot; the reminder notice is local (T9), it fires from the
  /// cache too.
  Future<void> _goOffline() async {
    final cached = await _loader.goOffline();
    if (!mounted) return;
    setState(() {});
    if (cached != null) await _reminders?.sync(cached.memos);
  }

  /// One retry tick (the loader fires it while offline): the moment the
  /// server answers, the screen goes back to its normal live behavior,
  /// already showing fresh data.
  Future<void> _tryReconnect() async {
    if (_checkingConnection) return;
    _checkingConnection = true;
    try {
      final data = await _load();
      if (!mounted) return;
      _loader.backOnline();
      setState(() {
        _future = Future.value(data);
      });
    } on ApiException catch (e) {
      if (e.isUnauthorized && mounted) {
        // The credential died while we were offline; now that the server
        // can finally say so, sign out like any other dead session.
        _loader.stopRetrying();
        _signedOut();
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
    final picked = await showTagFilterSheet(context, session: widget.session);
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

  /// Offers the instance taxonomy (ADR-0002); picking one filters the list.
  Future<void> _pickCategoryFilter() async {
    final picked =
        await showCategoryFilterSheet(context, session: widget.session);
    if (picked == null) return;
    setState(() {
      _filterCategory = picked;
      _future = _load()..ignore();
    });
  }

  void _clearCategoryFilter() {
    setState(() {
      _filterCategory = null;
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
      builder: (_) => MemoEditScreen(
          session: widget.session,
          showReminder: widget.showReminder,
          now: widget.reminderNow,
          memo: memo),
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
    if (_loader.offline) {
      await _openReadOnlyViewer(memo);
    } else {
      await _openEditor(memo);
    }
  }

  /// The recycle bin (T5); anything may have come back out of it.
  Future<void> _openTrash() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TrashScreen(session: widget.session),
    ));
    _reload();
  }

  /// The app-bar title: the filters in force, or the app name.
  String get _listTitle {
    final parts = <String>[
      if (_filterCategory != null) '分类：${_filterCategory!.name}',
      if (_filterTag != null) '标签：$_filterTag',
    ];
    return parts.isEmpty ? 'Meridian' : parts.join(' · ');
  }

  /// What an empty list says, naming the filter in force.
  String get _emptyMessage {
    if (_searchQuery != null) return '未找到匹配的备忘录';
    if (_filterCategory != null && _filterTag != null) return '该筛选下暂无备忘录';
    if (_filterCategory != null) return '该分类下暂无备忘录';
    if (_filterTag != null) return '该标签下暂无备忘录';
    return '暂无备忘录';
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
            : Text(_listTitle),
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
              onPressed: _loader.offline ? null : _openSearch,
            ),
          if (_filterTag != null)
            IconButton(
              key: const Key('clear_filter_button'),
              icon: const Icon(Icons.close),
              tooltip: '清除筛选',
              onPressed: _clearFilter,
            ),
          if (_filterCategory != null)
            IconButton(
              key: const Key('clear_category_filter_button'),
              icon: const Icon(Icons.close),
              tooltip: '清除分类筛选',
              onPressed: _clearCategoryFilter,
            ),
          IconButton(
            key: const Key('filter_button'),
            icon: const Icon(Icons.filter_list),
            tooltip: '按标签筛选',
            onPressed: _loader.offline ? null : _pickFilter,
          ),
          IconButton(
            key: const Key('category_filter_button'),
            icon: const Icon(Icons.category_outlined),
            tooltip: '按分类筛选',
            onPressed: _loader.offline ? null : _pickCategoryFilter,
          ),
          IconButton(
            key: const Key('trash_button'),
            icon: const Icon(Icons.delete_outline),
            tooltip: '回收站',
            // The recycle bin is server data, and its actions are writes.
            onPressed: _loader.offline ? null : _openTrash,
          ),
          IconButton(icon: const Icon(Icons.logout), tooltip: '退出登录', onPressed: widget.onSignOut),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('new_memo_button'),
        tooltip: _loader.offline ? '离线中，暂不可新建' : '新建备忘录',
        onPressed: _loader.offline ? null : _openEditor,
        child: const Icon(Icons.add),
      ),
      body: _loader.offline
          ? _offlineBody()
          : FutureBuilder<MemoListData>(
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
    final data = _loader.cachedData;
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
      final message = _emptyMessage;
      return Center(child: Text(message));
    }
    return ListView.builder(
      key: const Key('memo_list'),
      itemCount: memos.length,
      itemBuilder: (context, i) {
        final memo = memos[i];
        // The preview shows the rendered text, never the Markdown source
        // (ADR-0006): the same parse the editor and reader run, collapsed
        // to one paragraph; the row clips it to one line.
        final preview =
            memo.body.isEmpty ? '' : markdownPlainText(memo.body);
        return ListTile(
          title: Text(memo.title),
          subtitle: preview.isEmpty
              ? null
              : Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
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
  }
}
