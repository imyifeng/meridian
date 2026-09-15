import 'package:flutter/material.dart';

import '../api_client.dart';
import '../confirmed_draft_store.dart';
import '../session.dart';
import '../widgets/draft_card.dart';
import '../widgets/offline_banner.dart';
import 'memo_view_screen.dart';

/// The 智能体 page (#76): the resident Conversation (the glossary's) as a
/// chat — replies stream in frame by frame, a Draft renders as the miniature
/// create form the user confirms, and the whole record is clearable. The
/// page has its own states in a fixed priority: offline (input disabled,
/// banner up) over an unavailable agent — the server error frame's
/// not_configured/disabled code — over the normal chat.
class AgentScreen extends StatefulWidget {
  final MeridianSession session;

  /// Booted without a reachable server on a cached snapshot (ADR-0003): the
  /// agent needs the server for everything, so the input is dead until a
  /// retry succeeds elsewhere.
  final bool initialOffline;

  /// The device-local 已确认草稿集合 (#76 review): which draft cards this
  /// device already confirmed, so a restored conversation cannot confirm
  /// them twice.
  final ConfirmedDraftStore confirmedDraftStore;

  final VoidCallback onSignOut;

  const AgentScreen({
    super.key,
    required this.session,
    required this.confirmedDraftStore,
    this.initialOffline = false,
    required this.onSignOut,
  });

  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

/// One message in the flow. The draft card's editable state lives in its
/// [DraftCardModel] (see widgets/draft_card.dart), so what the user typed
/// survives list rebuilds and off-screen recycling — the message is the
/// state, the card is its view.
class _ChatMessage {
  /// Local uniqueness for widget keys: live turns have no server id yet,
  /// and two adjacent draft-carrying assistant rows must never share one.
  final int seq;
  final String role; // 'user' | 'assistant'
  String text;

  /// The display record's server id, when this message came from (or was
  /// later matched to) one — the 已确认草稿集合's key.
  int? recordId;

  /// Assistant rows only: the draft card this turn proposed, if any.
  DraftCardModel? draftCard;

  bool awaitingInput = false;

  _ChatMessage.user(this.seq, this.text) : role = 'user';

  _ChatMessage.assistant(this.seq, this.text) : role = 'assistant';

  /// The display record's assistant row; a draft-carrying one seeds its card
  /// through the model's single factory (the same path a live draft takes).
  _ChatMessage.record(this.seq, AgentRecord record)
      : role = record.role,
        text = record.content,
        recordId = record.id {
    final draft = record.draft;
    if (draft == null) return;
    draftCard = DraftCardModel.fromAgentDraft(draft);
    awaitingInput = record.awaitingInput;
  }
}

class _AgentScreenState extends State<AgentScreen> {
  final List<_ChatMessage> _messages = [];
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  /// Local sequence for widget keys; pairs with the store's server ids only
  /// after a record has been matched (see _recordConfirmation).
  int _nextSeq = 0;

  /// The taxonomy for draft cards; null until loaded, empty on failure.
  List<Category>? _categories;

  /// messageId → memoId, the store's content kept hot for rendering.
  final Map<int, int> _confirmedDrafts = {};

  bool _offline = false;
  bool _loading = false;

  /// True once the server's error frame diagnosed the agent as 未配置 or
  /// 已停用 (by code, not by text); [_unavailableMessage] is the frame's
  /// text, safe to show.
  bool _unavailable = false;
  String _unavailableCode = '';
  String _unavailableMessage = '';

  /// One turn in flight: input locked, waiting indicator up until the first
  /// frame lands.
  bool _streaming = false;
  bool _waiting = false;

  /// The last turn's declaration — an open task keeps the input inviting
  /// the user to finish it.
  bool _awaitingInput = false;

  @override
  void initState() {
    super.initState();
    _offline = widget.initialOffline;
    if (!_offline) {
      _loading = true;
      _loadConfirmedDrafts();
      _loadHistory();
    }
    _loadCategories();
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  MeridianApi get _api => widget.session.api;
  String get _token => widget.session.token;

  Future<void> _loadConfirmedDrafts() async {
    final entries = await widget.confirmedDraftStore.read();
    if (!mounted) return;
    setState(() {
      _confirmedDrafts
        ..clear()
        ..addEntries([for (final e in entries) MapEntry(e.messageId, e.memoId)]);
    });
    _markConfirmedHistory();
  }

  /// Restored records this device already confirmed render as created — no
  /// second confirmation, no second memo.
  void _markConfirmedHistory() {
    var changed = false;
    for (final message in _messages) {
      final card = message.draftCard;
      if (card == null || card.confirmed) continue;
      final memoId = _confirmedDrafts[message.recordId];
      if (memoId == null) continue;
      card
        ..status = DraftStatus.created
        ..createdMemoId = memoId;
      changed = true;
    }
    if (changed) setState(() {});
  }

  Future<void> _loadHistory() async {
    setState(() => _loading = true);
    try {
      final records = await _api.agentMessages(_token);
      if (!mounted) return;
      setState(() {
        _messages.clear();
        _nextSeq = 0;
        for (final record in records) {
          _messages.add(_ChatMessage.record(_nextSeq++, record));
        }
        _awaitingInput = records.isNotEmpty && records.last.awaitingInput;
        _loading = false;
      });
      _markConfirmedHistory();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isUnauthorized) {
        widget.onSignOut();
        return;
      }
      setState(() {
        _loading = false;
        // The record is what this page is; without the server there is
        // nothing to show but the offline truth.
        if (e.isUnreachable) _offline = true;
      });
    }
  }

  void _loadCategories() {
    _api.categories(_token).then((categories) {
      if (mounted) setState(() => _categories = categories);
    }).catchError((_) {
      // The picker is a convenience over a fixed taxonomy: an empty list
      // reads as '分类加载失败' on the card, with a retry.
      if (mounted) setState(() => _categories = const <Category>[]);
    });
  }

  Future<void> _send() async {
    final content = _input.text.trim();
    if (content.isEmpty || _streaming || _offline) return;
    final now = DateTime.now();
    final userMessage = _ChatMessage.user(_nextSeq++, content);
    setState(() {
      _messages.add(userMessage);
      _input.clear();
      _streaming = true;
      _waiting = true;
      _unavailable = false;
      _unavailableCode = '';
      _unavailableMessage = '';
    });
    _ChatMessage? turnAssistant;
    _ChatMessage assistantFor() {
      final existing = turnAssistant;
      if (existing != null) return existing;
      final created = _ChatMessage.assistant(_nextSeq++, '');
      turnAssistant = created;
      _messages.add(created);
      return created;
    }

    void applyEvent(AgentEvent event) {
      switch (event) {
        case AgentDeltaEvent(:final text):
          assistantFor().text += text;
        case AgentDraftEvent(:final draft):
          assistantFor().draftCard = DraftCardModel.fromAgentDraft(draft);
        case AgentDoneEvent(:final awaitingInput):
          _awaitingInput = awaitingInput;
          turnAssistant?.awaitingInput = awaitingInput;
        case AgentErrorEvent(:final message, :final code):
          if (code == 'not_configured' || code == 'disabled') {
            // The availability gate: the turn was never recorded
            // server-side, so the optimistic bubble goes too — the page
            // becomes the unavailable state.
            _unavailable = true;
            _unavailableCode = code;
            _unavailableMessage = message;
            _messages.remove(userMessage);
          } else {
            // A failure the server did record the turn up to: the message
            // stays, the failure text speaks as the assistant's last word.
            _messages.add(_ChatMessage.assistant(_nextSeq++, message));
          }
      }
    }

    try {
      final stream = await _api.sendAgentMessage(_token,
          content: content,
          localTime: rfc3339Local(now),
          timezone: now.timeZoneName);
      await for (final event in stream) {
        if (!mounted) return;
        setState(() => applyEvent(event));
      }
      if (!mounted) return;
      setState(() {
        _streaming = false;
        _waiting = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _streaming = false;
        _waiting = false;
        // Nothing was recorded server-side (the request never completed),
        // so the optimistic bubble must not pretend otherwise.
        _messages.remove(userMessage);
        if (e.isUnreachable) _offline = true;
      });
      if (e.isUnauthorized) {
        widget.onSignOut();
      } else if (!e.isUnreachable) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('发送失败，请重试')));
      }
    } catch (_) {
      // The stream died mid-reply (http.ClientException and any other
      // failure the protocol did not speak): the turn is over either way —
      // unlock, keep whatever streamed, and say what happened.
      if (!mounted) return;
      setState(() {
        _streaming = false;
        _waiting = false;
        _messages.add(_ChatMessage.assistant(_nextSeq++, '连接中断，本次回复不完整，请重试'));
      });
    }
  }

  Future<void> _confirmDraft(_ChatMessage message) async {
    final card = message.draftCard;
    if (card == null || card.creating || card.confirmed) return;
    if (_offline) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('离线中，无法创建备忘录，请恢复联网后再试')));
      return;
    }
    final title = card.title.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('标题不能为空')));
      return;
    }
    final categories = _categories;
    final categoryId = categories == null || categories.isEmpty
        ? card.categoryId
        : resolveDraftCategoryId(card.categoryId, categories);
    setState(() => card.creating = true);
    try {
      final memo = await _api.createMemo(_token,
          title: title,
          body: card.body,
          categoryId: categoryId,
          tags: card.tags.isEmpty ? null : List.of(card.tags),
          remindAt: card.remindAt,
          remindRule: card.remindRule);
      if (!mounted) return;
      setState(() {
        card
          ..createdMemo = memo
          ..createdMemoId = memo.id
          ..status = DraftStatus.created;
      });
      await _recordConfirmation(message, card, memo.id);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isUnauthorized) {
        widget.onSignOut();
      } else if (e.isUnreachable) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('离线中，无法创建备忘录，请恢复联网后再试')));
      } else {
        final reason =
            e.code == 'unknown_category' ? '该分类已不存在，请重新选择' : '创建失败，请重试';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(reason)));
      }
    } finally {
      if (mounted) setState(() => card.creating = false);
    }
  }

  /// Remembers the confirmation against the record's server id: the turn's
  /// assistant row is already in the display record (it was written before
  /// done), so one refresh finds it — the last unconfirmed draft row equal
  /// to this card's wire draft. Best effort: a failed refresh costs only a
  /// re-confirmable card on the next visit.
  Future<void> _recordConfirmation(
      _ChatMessage message, DraftCardModel card, int memoId) async {
    try {
      final records = await _api.agentMessages(_token);
      AgentRecord? match;
      for (final record in records.reversed) {
        final draft = record.draft;
        if (draft == null) continue;
        if (_confirmedDrafts.containsKey(record.id)) continue;
        if (card.isSameSource(draft)) {
          match = record;
          break;
        }
      }
      if (match == null) return;
      _confirmedDrafts[match.id] = memoId;
      message.recordId = match.id;
      await widget.confirmedDraftStore.write([
        for (final entry in _confirmedDrafts.entries)
          ConfirmedDraft(messageId: entry.key, memoId: entry.value),
      ]);
    } on ApiException {
      // The memo exists either way; the set is a convenience, not the truth.
    }
  }

  /// 有问题 (the ticket's second button): no auto-message — the card steps
  /// out of its confirmation state (never to confirm from here), and the
  /// user says the specifics in their own words with the input focused.
  void _questionDraft(_ChatMessage message) {
    setState(() => message.draftCard?.status = DraftStatus.questioned);
    FocusScope.of(context).requestFocus(_inputFocus);
  }

  Future<void> _openCreated(_ChatMessage message) async {
    final card = message.draftCard;
    if (card == null) return;
    var memo = card.createdMemo;
    final memoId = card.createdMemoId;
    if (memo == null && memoId != null) {
      try {
        memo = await _api.memo(_token, id: memoId);
      } on ApiException {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('打开失败，请重试')));
        return;
      }
    }
    if (!mounted) return;
    final shown = memo;
    if (shown == null) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => MemoViewScreen(memo: shown)));
  }

  Future<void> _clearConversation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空聊天记录'),
        content: const Text('将删除当前会话的全部聊天记录，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _api.clearAgentMessages(_token);
      if (!mounted) return;
      setState(() {
        _messages.clear();
        _awaitingInput = false;
        _unavailable = false;
        _unavailableCode = '';
        _unavailableMessage = '';
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isUnauthorized) {
        widget.onSignOut();
      } else if (e.isUnreachable) {
        setState(() => _offline = true);
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('清空失败，请重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('智能体'),
        actions: [
          IconButton(
            key: const Key('clear_conversation_button'),
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空聊天记录',
            onPressed: _offline || _streaming || _unavailable
                ? null
                : _clearConversation,
          ),
        ],
      ),
      body: _unavailable
          ? _unavailableState(colors)
          : Column(
              children: [
                if (_offline)
                  const OfflineBanner(
                    key: Key('agent_offline_banner'),
                    message: '离线模式：智能体暂不可用，恢复联网后再试',
                  ),
                Expanded(child: _body()),
                _inputBar(),
              ],
            ),
    );
  }

  /// 未配置/停用 (the error frame's code), in the placeholder's style: what
  /// happened, what to do about it, and a way back in case the
  /// administrator fixes the AI 设置 without a restart.
  Widget _unavailableState(ColorScheme colors) {
    final disabled = _unavailableCode == 'disabled';
    return Center(
      key: const Key('agent_unavailable'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline, size: 48, color: colors.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(disabled ? '智能体已停用' : '智能体尚未配置',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            _unavailableMessage,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextButton(
            key: const Key('agent_retry_button'),
            onPressed: () => setState(() {
              _unavailable = false;
              _unavailableCode = '';
              _unavailableMessage = '';
            }),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_messages.isEmpty) {
      return _freshState();
    }
    return ScrollConfiguration(
      // The chat list opts out of the Android stretch overscroll: its
      // Transform wrapper sits between the viewport and the newest child,
      // which is also where every tap lands.
      behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
      child: ListView(
        key: const Key('agent_messages'),
        reverse: true, // newest at the bottom, like every chat
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        children: [
          if (_waiting) _waitingRow(),
          for (final message in _messages.reversed) _messageTile(message),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _freshState() {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 48, color: colors.onSurfaceVariant),
          const SizedBox(height: 16),
          Text('让智能体帮你记录与查找备忘录',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '试试：帮我记一条明天上午九点的周会',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// The in-flight turn before its first frame: what the user can see the
  /// agent doing while the model works (user story's wording).
  Widget _waitingRow() {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: const Key('agent_waiting'),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            const Text('正在搜索备忘录…'),
          ],
        ),
      ),
    );
  }

  Widget _messageTile(_ChatMessage message) {
    final card = message.draftCard;
    return Column(
      key: Key('agent_message_${message.seq}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _bubble(message),
        if (card != null)
          DraftCard(
            key: Key('draft_card_${message.seq}'),
            model: card,
            categories: _categories,
            offline: _offline,
            onCategoriesRetry: _loadCategories,
            onConfirm: () => _confirmDraft(message),
            onQuestion: () => _questionDraft(message),
            onOpen: () => _openCreated(message),
            onChanged: () => setState(() {}),
          ),
      ],
    );
  }

  Widget _bubble(_ChatMessage message) {
    final colors = Theme.of(context).colorScheme;
    final fromUser = message.role == 'user';
    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: fromUser
              ? colors.primaryContainer
              : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(fromUser ? 16 : 4),
            bottomRight: Radius.circular(fromUser ? 4 : 16),
          ),
        ),
        child: Text(message.text),
      ),
    );
  }

  Widget _inputBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: const Key('agent_input_field'),
                controller: _input,
                focusNode: _inputFocus,
                enabled: !_offline && !_streaming,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: _awaitingInput ? '继续补充，任务还没完成' : '给智能体发消息',
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              key: const Key('send_button'),
              tooltip: '发送',
              onPressed: _offline || _streaming ? null : _send,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
