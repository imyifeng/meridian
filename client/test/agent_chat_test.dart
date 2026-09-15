import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/app.dart';
import 'package:meridian/confirmed_draft_store.dart';
import 'package:meridian/memo_cache.dart';
import 'package:meridian/token_store.dart';
import 'package:meridian/widgets/draft_card.dart';

import 'fake_meridian_server.dart';
import 'login_harness.dart';

// The 智能体 chat page (#76): streamed replies, draft cards as the
// miniature create form, retrieval waiting state, clearable conversation,
// and the unavailable/offline states. The fake server scripts the SSE
// frames; each frame arrives as its own chunk on the fake clock, so
// incremental rendering is observable mid-stream with pump(duration).

Finder _navLabel(String label) => find.descendant(
      of: find.byKey(const Key('nav_bar')),
      matching: find.text(label),
    );

MeridianApp clientApp(FakeMeridianServer fake) => MeridianApp(
      baseUrl: fake.url,
      tokenStore: InMemoryTokenStore(),
      apiClient: fake.client,
    );

MeridianApp clientAppWith(FakeMeridianServer fake, InMemoryTokenStore tokens,
        InMemoryMemoCache cache,
        {ConfirmedDraftStore? confirmedDraftStore}) =>
    MeridianApp(
      baseUrl: fake.url,
      tokenStore: tokens,
      memoCache: cache,
      confirmedDraftStore: confirmedDraftStore,
      apiClient: fake.client,
    );

void configureAI(FakeMeridianServer fake) {
  fake.aiSettings = {
    'base_url': 'https://llm.example',
    'model': 'test-model',
    'api_key': 'secret-key',
    'enabled': true,
  };
}

/// Boots the app, signs in, opens the 智能体 tab with AI 配置 available,
/// and hands back the fake for scripting and assertions.
Future<FakeMeridianServer> openAgentChat(
  WidgetTester tester, {
  void Function(FakeMeridianServer fake)? setup,
}) async {
  final fake = FakeMeridianServer();
  fake.registerUser('yifeng', 'correct horse');
  configureAI(fake);
  setup?.call(fake);
  await pumpAndLogin(tester, clientApp(fake), 'yifeng', 'correct horse');
  await tester.tap(_navLabel('智能体'));
  await tester.pumpAndSettle();
  return fake;
}

void main() {
  testWidgets('发送消息后逐字流式渲染，等待时显示检索状态', (tester) async {
    final fake = await openAgentChat(tester, setup: (fake) {
      fake.agentReplies = [
        [
          {'type': 'delta', 'text': '你好'},
          {'type': 'delta', 'text': '，世界'},
          {'type': 'done', 'awaiting_input': false},
        ],
      ];
    });

    await tester.enterText(
        find.byKey(const Key('agent_input_field')), '记一条备忘录');
    await tester.tap(find.byKey(const Key('send_button')));
    // The turn is in flight: the user's words are up, the waiting state
    // speaks before the model's first word lands, and the input is locked.
    await tester.pump();
    expect(find.text('记一条备忘录'), findsOneWidget);
    expect(find.text('正在搜索备忘录…'), findsOneWidget);
    expect(find.text('你好'), findsNothing);

    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('你好'), findsOneWidget);
    expect(find.text('你好，世界'), findsNothing);

    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('你好，世界'), findsOneWidget);

    await tester.pumpAndSettle();
    // The turn is over: the waiting state is gone and the input is back.
    expect(find.text('正在搜索备忘录…'), findsNothing);
    final field = tester.widget<TextField>(
        find.byKey(const Key('agent_input_field')));
    expect(field.enabled, isTrue);
    expect(fake.agentRequests, hasLength(1));
  });

  testWidgets('发送请求带上消息正文、本地时间（含偏移）与时区名', (tester) async {
    final fake = await openAgentChat(tester, setup: (fake) {
      fake.agentReplies = [
        [
          {'type': 'delta', 'text': '好的'},
          {'type': 'done', 'awaiting_input': false},
        ],
      ];
    });

    await tester.enterText(
        find.byKey(const Key('agent_input_field')), '帮我记一笔');
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();

    expect(fake.agentRequests, hasLength(1));
    final body = fake.agentRequests.single;
    expect(body['content'], '帮我记一笔');
    expect(body['local_time'],
        matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$')));
    expect((body['timezone'] as String).isNotEmpty, isTrue);
  });

  testWidgets('草稿卡片可改字段，点"没问题"按卡片内容创建备忘录', (tester) async {
    final fake = await openAgentChat(tester, setup: (fake) {
      fake.createCategory('工作');
      fake.agentReplies = [
        [
          {'type': 'delta', 'text': '好的，这是草稿：'},
          {
            'type': 'draft',
            'draft': {
              'title': '购物',
              'content': '牛奶',
              'category_id': 2,
              'remind_at': '2026-09-16T09:00:00+08:00',
              'remind_rule': {'mode': 'daily', 'interval': 1, 'hour': 9, 'minute': 0},
            },
          },
          {'type': 'done', 'awaiting_input': true},
        ],
      ];
    });

    await tester.enterText(
        find.byKey(const Key('agent_input_field')), '帮我记买牛奶');
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();

    // The card is the miniature create form: its fields carry the draft.
    final titleField = tester.widget<TextField>(
        find.byKey(const Key('draft_title_field')));
    expect(titleField.controller!.text, '购物');

    // 手动调整：标题、正文、标签。
    await tester.enterText(find.byKey(const Key('draft_title_field')), '周六购物清单');
    await tester.enterText(find.byKey(const Key('draft_body_field')), '牛奶、鸡蛋');
    await tester.enterText(find.byKey(const Key('draft_tag_field')), '生活');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('draft_add_tag_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('draft_tag_chip_生活')), findsOneWidget);

    // 分类可改：切回内置的 未分类。
    await tester.tap(find.byKey(const Key('draft_category_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('未分类').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('draft_confirm_button')));
    await tester.pumpAndSettle();

    // 创建请求与卡片字段一致：改过的标题正文、手选分类、仅手动加的标签、
    // 草稿自带的提醒（一次性时间点由循环规则给出）。
    expect(fake.memoByTitle('周六购物清单')['body'], '牛奶、鸡蛋');
    expect(fake.memoByTitle('周六购物清单')['category_id'], fake.uncategorizedId);
    expect(fake.memoByTitle('周六购物清单')['tags'], ['生活']);
    expect(fake.remindAtOf('周六购物清单'),
        DateTime.parse('2026-09-16T09:00:00+08:00').toLocal());
    expect(fake.remindRuleOf('周六购物清单'),
        {'mode': 'daily', 'interval': 1, 'hour': 9, 'minute': 0});

    // 已创建态：标出"已创建"，可跳转查看该备忘录。
    expect(find.text('已创建'), findsOneWidget);
    await tester.tap(find.byKey(const Key('draft_open_button')));
    await tester.pumpAndSettle();
    expect(find.text('查看备忘录'), findsOneWidget);
    expect(find.text('周六购物清单'), findsOneWidget);
  });

  testWidgets('点"有问题"不发创建请求，卡片留作上下文，回到对话继续说', (tester) async {
    final fake = await openAgentChat(tester, setup: (fake) {
      fake.agentReplies = [
        [
          {
            'type': 'draft',
            'draft': {'title': '购物', 'content': '牛奶', 'category_id': 1},
          },
          {'type': 'done', 'awaiting_input': true},
        ],
      ];
    });

    await tester.enterText(
        find.byKey(const Key('agent_input_field')), '帮我记买牛奶');
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('draft_reject_button')));
    await tester.pumpAndSettle();

    // 确认入口消失了，卡片说明继续对话。
    expect(find.byKey(const Key('draft_confirm_button')), findsNothing);
    expect(find.byKey(const Key('draft_reject_button')), findsNothing);
    expect(find.text('有问题，请在下方继续说明'), findsOneWidget);
    // 输入框自动聚焦，对话直接继续。
    final field = tester.widget<TextField>(
        find.byKey(const Key('agent_input_field')));
    expect(field.focusNode!.hasFocus, isTrue);
    // 卡片字段仍可调整，对话可以继续说细则。
    await tester.enterText(find.byKey(const Key('draft_title_field')), '改一下标题');
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('agent_input_field')), '标题换成周末采购');
    await tester.pumpAndSettle();
    // 没有任何备忘录落库。
    expect(() => fake.memoByTitle('购物'), throwsStateError);
    expect(() => fake.memoByTitle('改一下标题'), throwsStateError);
  });

  testWidgets('草稿卡片标签区为空且仅手动添加，创建请求只带手动标签', (tester) async {
    final fake = await openAgentChat(tester, setup: (fake) {
      fake.agentReplies = [
        [
          {
            'type': 'draft',
            'draft': {
              'title': '周会',
              'content': '内容里提到"标签：工作、急"，也不算数',
              'category_id': 1,
            },
          },
          {'type': 'done', 'awaiting_input': true},
        ],
      ];
    });

    await tester.enterText(find.byKey(const Key('agent_input_field')), '记周会');
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();

    // 模型没给标签，卡片上一个标签芯片都没有：AI 不预填。
    expect(
      find.descendant(
          of: find.byType(DraftCard), matching: find.byType(InputChip)),
      findsNothing,
    );

    await tester.enterText(find.byKey(const Key('draft_tag_field')), '手动加的');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('draft_add_tag_button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('draft_confirm_button')));
    await tester.pumpAndSettle();

    expect(fake.memoByTitle('周会')['tags'], ['手动加的']);
  });

  testWidgets('进入页面渲染历史会话，草稿行渲染为可确认的卡片', (tester) async {
    final fake = await openAgentChat(tester, setup: (fake) {
      fake.seedConversation('yifeng', [
        {'role': 'user', 'content': '帮我记一下周六要买牛奶'},
        {
          'role': 'assistant',
          'content': '好的，这是草稿，请确认：',
          'awaiting_input': true,
          'draft': {
            'title': '周六采购',
            'content': '牛奶',
            'category_id': 1,
          },
        },
      ]);
    });

    // 历史原样在列：最旧的消息在列表顶上，滚上去看得到。
    await tester.dragUntilVisible(
      find.text('帮我记一下周六要买牛奶'),
      find.byKey(const Key('agent_messages')),
      const Offset(0, 100),
    );
    await tester.pumpAndSettle();
    expect(find.text('帮我记一下周六要买牛奶'), findsOneWidget);
    expect(find.text('好的，这是草稿，请确认：'), findsOneWidget);
    final titleField = tester.widget<TextField>(
        find.byKey(const Key('draft_title_field')));
    expect(titleField.controller!.text, '周六采购');

    // 历史卡片仍可确认——滚回最下方（卡片所在处）再确认，任务还开着。
    await tester.dragUntilVisible(
      find.byKey(const Key('draft_confirm_button')),
      find.byKey(const Key('agent_messages')),
      const Offset(0, -100),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('draft_confirm_button')));
    await tester.pumpAndSettle();
    expect(fake.memoByTitle('周六采购')['body'], '牛奶');
    expect(find.text('已创建'), findsOneWidget);
  });

  testWidgets('清空聊天记录：二次确认后本地与服务器记录一致清空', (tester) async {
    final fake = await openAgentChat(tester, setup: (fake) {
      fake.agentReplies = [
        [
          {'type': 'delta', 'text': '好的，记上了'},
          {'type': 'done', 'awaiting_input': false},
        ],
      ];
    });

    await tester.enterText(
        find.byKey(const Key('agent_input_field')), '帮我记买牛奶');
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();
    expect(find.text('好的，记上了'), findsOneWidget);
    expect(fake.conversationOf('yifeng'), hasLength(2));

    // 先取消：什么都不动。
    await tester.tap(find.byKey(const Key('clear_conversation_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('好的，记上了'), findsOneWidget);
    expect(fake.agentClearCalls, 0);

    // 再清空：确认后消息流回到空会话，服务器记录同空。
    await tester.tap(find.byKey(const Key('clear_conversation_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('好的，记上了'), findsNothing);
    expect(find.text('帮我记买牛奶'), findsNothing);
    expect(fake.agentClearCalls, 1);
    expect(fake.conversationOf('yifeng'), isEmpty);

    // 清空后输入栏照常可用，会话状态一致。
    final field = tester.widget<TextField>(
        find.byKey(const Key('agent_input_field')));
    expect(field.enabled, isTrue);
    expect(find.byKey(const Key('agent_waiting')), findsNothing);
  });

  testWidgets('AI 未配置：发送后显示"请联系管理员"空态，未落库的消息不残留', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    // 默认 aiSettings 全空：实例从未配置过 AI。
    await pumpAndLogin(tester, clientApp(fake), 'yifeng', 'correct horse');
    await tester.tap(_navLabel('智能体'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('agent_input_field')), '在吗');
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('agent_unavailable')), findsOneWidget);
    expect(find.text('智能体尚未配置'), findsOneWidget);
    expect(find.textContaining('请联系管理员'), findsOneWidget);
    // 服务端没有记录这次发送（回应只是错误帧），本地也不留乐观气泡。
    expect(fake.conversationOf('yifeng'), isEmpty);
    expect(find.text('在吗'), findsNothing);

    // 管理员修好 AI 设置后无需重启即可重试。
    configureAI(fake);
    fake.agentReplies = [
      [
        {'type': 'done', 'awaiting_input': false},
      ],
    ];
    await tester.tap(find.byKey(const Key('agent_retry_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agent_input_field')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('agent_input_field')), '在吗');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();
    // 第一次发送（被网关拒绝的那次）之外，重试真正发出去了一次。
    expect(fake.agentRequests, hasLength(2));
  });

  testWidgets('AI 已停用：发送后显示停用空态', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.aiSettings = {
      'base_url': 'https://llm.example',
      'model': 'test-model',
      'api_key': 'secret-key',
      'enabled': false,
    };
    await pumpAndLogin(tester, clientApp(fake), 'yifeng', 'correct horse');
    await tester.tap(_navLabel('智能体'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('agent_input_field')), '在吗');
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('agent_unavailable')), findsOneWidget);
    expect(find.text('智能体已停用'), findsOneWidget);
    expect(find.textContaining('请联系管理员'), findsOneWidget);
  });

  testWidgets('离线：智能体明确不可用，输入与清空都禁用', (tester) async {
    // 登录一次让本地缓存有快照，再无网重启——离线进入智能体页。
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    fake.seedMemo('yifeng', '购物清单', body: '牛奶');
    final tokens = InMemoryTokenStore();
    final cache = InMemoryMemoCache();
    await tester.pumpWidget(clientAppWith(fake, tokens, cache));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('username_field')), 'yifeng');
    await tester.enterText(
        find.byKey(const Key('password_field')), 'correct horse');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();

    fake.offline = true;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(clientAppWith(fake, tokens, cache));
    await tester.pumpAndSettle();

    await tester.tap(_navLabel('智能体'));
    await tester.pumpAndSettle();

    // 离线优先于一切：横幅明示不可用，输入、发送、清空全禁用。
    expect(find.byKey(const Key('agent_offline_banner')), findsOneWidget);
    final field = tester.widget<TextField>(
        find.byKey(const Key('agent_input_field')));
    expect(field.enabled, isFalse);
    final send =
        tester.widget<IconButton>(find.byKey(const Key('send_button')));
    expect(send.onPressed, isNull);
    final clear = tester.widget<IconButton>(
        find.byKey(const Key('clear_conversation_button')));
    expect(clear.onPressed, isNull);
  });

  testWidgets('流式中途断流：输入解锁、错误可见，可再次发送', (tester) async {
    final fake = await openAgentChat(tester, setup: (fake) {
      fake.agentReplies = [
        [
          {'type': 'delta', 'text': '部分回复'},
          {'type': '_break'},
        ],
        [
          {'type': 'delta', 'text': '这次完整了'},
          {'type': 'done', 'awaiting_input': false},
        ],
      ];
    });

    await tester.enterText(
        find.byKey(const Key('agent_input_field')), '第一条');
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();

    // 部分流式文本保留，断流以助手错误气泡说明，输入恢复可用。
    expect(find.text('部分回复'), findsOneWidget);
    expect(find.text('连接中断，本次回复不完整，请重试'), findsOneWidget);
    final field = tester.widget<TextField>(
        find.byKey(const Key('agent_input_field')));
    expect(field.enabled, isTrue);
    expect(find.byKey(const Key('agent_waiting')), findsNothing);

    // 断流后可再次发送，新回复照常流式。
    await tester.enterText(
        find.byKey(const Key('agent_input_field')), '第二条');
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();
    expect(find.text('这次完整了'), findsOneWidget);
    expect(fake.agentRequests, hasLength(2));
  });

  testWidgets('普通错误帧（internal）以错误气泡显示，不进入不可用空态', (tester) async {
    final fake = await openAgentChat(tester); // 空脚本 → internal 错误帧

    await tester.enterText(find.byKey(const Key('agent_input_field')), '在吗');
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('agent_unavailable')), findsNothing);
    expect(find.text('回复生成失败，请稍后重试或联系管理员检查 AI 设置'),
        findsOneWidget);
    // 用户消息保留（服务端也记下了），只是回复失败。
    expect(find.text('在吗'), findsOneWidget);
    expect(fake.conversationOf('yifeng'), hasLength(1));
  });

  testWidgets('相邻两条草稿消息的字段互不串', (tester) async {
    await openAgentChat(tester, setup: (fake) {
      fake.seedConversation('yifeng', [
        {'role': 'user', 'content': '记两条'},
        {
          'role': 'assistant',
          'content': '第一张卡',
          'draft': {'title': '甲', 'content': '一', 'category_id': 1},
        },
        {
          'role': 'assistant',
          'content': '第二张卡',
          'draft': {'title': '乙', 'content': '二', 'category_id': 1},
        },
      ]);
    });
    await tester.pumpAndSettle();
    // 旧卡在视口外（sliver 懒构建），往上拖把它拽进来。
    await tester.drag(find.byKey(const Key('agent_messages')), const Offset(0, 300));
    await tester.pumpAndSettle();

    // 最新在下（树序在前）：at(0) 是 乙，at(1) 是 甲，各自 controller 独立。
    Finder titleAt(int index) =>
        find.byKey(const Key('draft_title_field')).at(index);
    expect(tester.widget<TextField>(titleAt(0)).controller!.text, '乙');
    expect(tester.widget<TextField>(titleAt(1)).controller!.text, '甲');

    // 只改第一张卡的标题，另一张不受影响。
    await tester.enterText(titleAt(0), '乙改');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(titleAt(0)).controller!.text, '乙改');
    expect(tester.widget<TextField>(titleAt(1)).controller!.text, '甲');
  });

  testWidgets('确认后重建页面：卡片为已创建态，不可再确认，可打开', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    configureAI(fake);
    fake.seedConversation('yifeng', [
      {'role': 'user', 'content': '帮我记买牛奶'},
      {
        'role': 'assistant',
        'content': '好的，这是草稿：',
        'awaiting_input': true,
        'draft': {'title': '牛奶', 'content': '两盒', 'category_id': 1},
      },
    ]);
    final store = InMemoryConfirmedDraftStore();
    final tokens = InMemoryTokenStore();
    final cache = InMemoryMemoCache();

    Future<void> boot() async {
      await tester.pumpWidget(clientAppWith(fake, tokens, cache,
          confirmedDraftStore: store));
      await tester.pumpAndSettle();
    }

    await boot();
    await tester.enterText(find.byKey(const Key('username_field')), 'yifeng');
    await tester.enterText(
        find.byKey(const Key('password_field')), 'correct horse');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();
    await tester.tap(_navLabel('智能体'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('draft_confirm_button')));
    await tester.pumpAndSettle();
    expect(find.text('已创建'), findsOneWidget);

    // 重建页面（同一个 store）：卡片直接是已创建态，没有确认入口，可打开。
    await tester.pumpWidget(const SizedBox());
    await boot();
    await tester.tap(_navLabel('智能体'));
    await tester.pumpAndSettle();

    expect(find.text('已创建'), findsOneWidget);
    expect(find.byKey(const Key('draft_confirm_button')), findsNothing);
    expect(find.byKey(const Key('draft_reject_button')), findsNothing);
    expect(find.byKey(const Key('draft_open_button')), findsOneWidget);

    // 打开按记忆的 memo id 取回备忘录。
    await tester.tap(find.byKey(const Key('draft_open_button')));
    await tester.pumpAndSettle();
    expect(find.text('查看备忘录'), findsOneWidget);
    expect(find.text('牛奶'), findsOneWidget);
  });

  testWidgets('离线时确认草稿：明确提示离线原因，卡片保持待确认', (tester) async {
    final fake = await openAgentChat(tester, setup: (fake) {
      fake.agentReplies = [
        [
          {
            'type': 'draft',
            'draft': {'title': '购物', 'content': '牛奶', 'category_id': 1},
          },
          {'type': 'done', 'awaiting_input': true},
        ],
      ];
    });

    await tester.enterText(
        find.byKey(const Key('agent_input_field')), '记买牛奶');
    await tester.tap(find.byKey(const Key('send_button')));
    await tester.pumpAndSettle();

    // 网络在确认前断掉（页面尚未察觉）：点"没问题"必须给出离线原因。
    fake.offline = true;
    await tester.tap(find.byKey(const Key('draft_confirm_button')));
    await tester.pumpAndSettle();

    expect(find.text('离线中，无法创建备忘录，请恢复联网后再试'), findsOneWidget);
    // 卡片保持待确认，恢复联网后可重试。
    expect(find.byKey(const Key('draft_confirm_button')), findsOneWidget);
    expect(find.text('已创建'), findsNothing);
  });
}
