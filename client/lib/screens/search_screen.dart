import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../memo_cache.dart';
import '../memo_filters.dart';
import '../memo_list_loader.dart';
import '../session.dart';
import '../widgets/memo_list_tile.dart';
import '../widgets/offline_banner.dart';
import 'filter_sheets.dart';
import 'memo_view_screen.dart';

/// The 搜索 page (#72): full-text search over the user's memos — title,
/// body, and tags — as its own tab, with the tag and category filters
/// stackable on top of the keyword. What feeds it lives in its own modules:
/// [MemoListLoader] for loads and the offline state (T8, ADR-0003), the
/// filter sheets for picking a tag or category. The page loads nothing
/// until there is something to search for.
class SearchScreen extends StatefulWidget {
  final MeridianSession session;
  final MemoCache cache;

  /// Booted without a reachable server on a cached snapshot (ADR-0003):
  /// search asks the server, so the page starts unavailable until a retry
  /// succeeds.
  final bool initialOffline;

  /// Fires when a search load comes back 401 while offline: the credential
  /// died, and sign-out is the shell's business.
  final VoidCallback onSignOut;

  const SearchScreen({
    super.key,
    required this.session,
    required this.cache,
    this.initialOffline = false,
    required this.onSignOut,
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  /// 输入即查 (T6): keystrokes wait this long for the next one before the
  /// query commits; the keyboard's search action commits at once.
  static const _debounceDelay = Duration(milliseconds: 300);

  late final MemoListLoader _loader;
  final _queryController = TextEditingController();
  Timer? _debounce;
  // The committed query (null = nothing to search for yet); a blank field
  // is no query.
  String? _query;
  String? _filterTag;
  // 分类筛选 (T14)：picked from the taxonomy sheet; categories are
  // read-only here (ADR-0002) — this only chooses among them.
  Category? _filterCategory;
  // Null until a query or filter gives the page something to load; the
  // body then shows the hint, not an empty list.
  Future<MemoListData>? _future;
  // Serialized reconnect attempts: a tick landing on a still-running load
  // is dropped, so a slow server never piles them up.
  bool _checkingConnection = false;

  /// The narrowing in force: keyword plus the stacked tag/category picks.
  MemoFilters get _filters =>
      MemoFilters(tag: _filterTag, category: _filterCategory, query: _query);

  @override
  void initState() {
    super.initState();
    _loader = MemoListLoader(session: widget.session, cache: widget.cache)
      ..onRetryTick = _tryReconnect;
    if (widget.initialOffline) {
      _goOffline();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _loader.dispose();
    _queryController.dispose();
    super.dispose();
  }

  /// Every `_future = _load()` carries `..ignore()`: load errors must be
  /// handled even when the FutureBuilder never subscribes because the load
  /// flipped the screen offline before the next frame.
  Future<MemoListData> _load() async {
    try {
      return await _loader.load(_filters);
    } on ApiException catch (e) {
      if (e.isUnreachable) await _goOffline();
      rethrow;
    }
  }

  /// Enters offline read-only mode with the loader (T8): search is a
  /// server query, so the page states it plainly and waits for the
  /// loader's retry ticks.
  Future<void> _goOffline() async {
    await _loader.goOffline();
    if (mounted) setState(() {});
  }

  /// One retry tick (the loader fires it while offline): the moment the
  /// server answers, the page goes back to its normal live behavior.
  Future<void> _tryReconnect() async {
    if (_checkingConnection) return;
    _checkingConnection = true;
    try {
      final data = await _loader.load(_filters);
      if (!mounted) return;
      _loader.backOnline();
      setState(() {
        _future = _filters.isFiltered ? Future.value(data) : null;
      });
    } on ApiException catch (e) {
      if (e.isUnauthorized && mounted) {
        // The credential died while we were offline; now that the server
        // can finally say so, sign out like any other dead session.
        _loader.stopRetrying();
        widget.onSignOut();
      }
      // Still unreachable: stay unavailable until the next tick.
    } finally {
      _checkingConnection = false;
    }
  }

  /// Keystrokes debounce into a search; the timer resets on every key.
  void _onQueryChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () => _runSearch(text));
  }

  /// The keyboard's search action skips the wait.
  void _onQuerySubmitted(String text) {
    _debounce?.cancel();
    _runSearch(text);
  }

  /// Commits the field's text; a blank query leaves the page only the
  /// stacked filters to search by.
  void _runSearch(String term) {
    final q = term.trim();
    setState(() {
      _query = q.isEmpty ? null : q;
      _future = _filters.isFiltered ? (_load()..ignore()) : null;
    });
  }

  /// Empties the field and drops every narrowing: back to the fresh hint.
  void _clearSearch() {
    _debounce?.cancel();
    _queryController.clear();
    setState(() {
      _query = null;
      _filterTag = null;
      _filterCategory = null;
      _future = null;
    });
  }

  /// Offers the user's own tag history (T4); picking one stacks it on top
  /// of the keyword and whatever else stands.
  Future<void> _pickTagFilter() async {
    final picked = await showTagFilterSheet(context, session: widget.session);
    if (picked == null || !mounted) return;
    setState(() {
      _filterTag = picked;
      _future = _load()..ignore();
    });
  }

  /// Offers the instance taxonomy (ADR-0002); picking one stacks it the
  /// same way. 只读的选择，不提供任何增减分类的途径 (ADR-0002)。
  Future<void> _pickCategoryFilter() async {
    final picked =
        await showCategoryFilterSheet(context, session: widget.session);
    if (picked == null || !mounted) return;
    setState(() {
      _filterCategory = picked;
      _future = _load()..ignore();
    });
  }

  /// Drops one stacked pick; the keyword and the other pick carry on.
  void _clearTagFilter() {
    setState(() {
      _filterTag = null;
      _future = _filters.isFiltered ? (_load()..ignore()) : null;
    });
  }

  void _clearCategoryFilter() {
    setState(() {
      _filterCategory = null;
      _future = _filters.isFiltered ? (_load()..ignore()) : null;
    });
  }

  /// The picks in force, as removable chips under the app bar: what the
  /// results are narrowed by besides the keyword.
  PreferredSizeWidget? get _filterChips {
    if (_filterTag == null && _filterCategory == null) return null;
    return PreferredSize(
      preferredSize: const Size.fromHeight(48),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            children: [
              if (_filterTag != null)
                FilterChip(
                  key: const Key('search_filter_chip'),
                  selected: true,
                  label: Text('标签：$_filterTag'),
                  onSelected: (_) => _clearTagFilter(),
                ),
              if (_filterCategory != null)
                FilterChip(
                  key: const Key('search_category_filter_chip'),
                  selected: true,
                  label: Text('分类：${_filterCategory!.name}'),
                  onSelected: (_) => _clearCategoryFilter(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// What the page shows before anything narrows it: not an empty result
  /// list, an invitation.
  Widget _hint() {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search, size: 48, color: colors.onSurfaceVariant),
          const SizedBox(height: 16),
          Text('输入关键词搜索备忘录', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '全文检索标题、正文与标签',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          key: const Key('search_field'),
          controller: _queryController,
          // Search runs on the server; offline there is nothing to type
          // into (T8) — the field goes dead until a retry tick reconnects.
          autofocus: !_loader.offline,
          enabled: !_loader.offline,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: '搜索标题、正文、标签',
            border: InputBorder.none,
          ),
          onChanged: _onQueryChanged,
          onSubmitted: _onQuerySubmitted,
        ),
        actions: [
          // Only while something stands to clear: a committed query or a
          // stacked filter. Empties the field and restores the fresh hint.
          if (_filters.isFiltered)
            IconButton(
              key: const Key('clear_search_button'),
              icon: const Icon(Icons.close),
              tooltip: '清空搜索',
              onPressed: _clearSearch,
            ),
          IconButton(
            key: const Key('search_filter_button'),
            icon: const Icon(Icons.filter_list),
            tooltip: '按标签筛选',
            onPressed: _loader.offline ? null : _pickTagFilter,
          ),
          IconButton(
            key: const Key('search_category_filter_button'),
            icon: const Icon(Icons.category_outlined),
            tooltip: '按分类筛选',
            onPressed: _loader.offline ? null : _pickCategoryFilter,
          ),
        ],
        bottom: _filterChips,
      ),
      body: _loader.offline
          ? _offlineBody()
          : _future == null
              ? _hint()
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
                            const Text('搜索失败'),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: () =>
                                  setState(() => _future = _load()..ignore()),
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      );
                    }
                    return _resultList(snapshot.data ??
                        MemoListData(const <Memo>[], const {}));
                  },
                ),
    );
  }

  /// Offline (T8): search is a server query, so the page says so plainly
  /// instead of pretending — the banner mirrors the home list's, and the
  /// retry tick (the loader's) brings the page back by itself.
  Widget _offlineBody() {
    return Column(
      children: [
        const OfflineBanner(
          key: Key('search_offline_banner'),
          message: '离线模式：暂不可搜索，恢复联网后自动恢复',
        ),
        const Expanded(child: Center(child: Text('暂不可搜索'))),
      ],
    );
  }

  /// The result rows, in the same shape as the home list: title, one-line
  /// plain-text preview (ADR-0008), the reminder mark and the category the
  /// memo lives in.
  Widget _resultList(MemoListData data) {
    final memos = data.memos;
    if (memos.isEmpty) {
      return const Center(child: Text('未找到匹配的备忘录'));
    }
    return ListView.builder(
      key: const Key('search_results'),
      itemCount: memos.length,
      itemBuilder: (context, i) {
        final memo = memos[i];
        return MemoListTile(
          memo: memo,
          categoryNames: data.categoryNames,
          // A result is a snapshot from the query, so it opens as the
          // reader (MemoViewScreen); editing stays the home list's business.
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => MemoViewScreen(memo: memo),
          )),
        );
      },
    );
  }
}
