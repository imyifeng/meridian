import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:meridian/api_client.dart';
import 'package:meridian/recurrence.dart';

void main() {
  // The agent reply protocol (#74/#75): one JSON object per SSE "data:"
  // frame — delta / draft / done / error, 200 text/event-stream even for
  // failures. These tests pin the client's consumption of that stream: chunk
  // boundaries anywhere (mid-line, mid-UTF-8-rune) must not change what the
  // caller sees.
  http.StreamedResponse sse(List<List<int>> chunks) => http.StreamedResponse(
        Stream<List<int>>.fromIterable(chunks),
        200,
        headers: {'content-type': 'text/event-stream'},
      );

  List<int> bytes(String text) => utf8.encode(text);

  Future<List<AgentEvent>> collect(http.Client client) async {
    final api =
        MeridianApi(baseUrl: 'http://fake.meridian.local', client: client);
    final stream = await api.sendAgentMessage('t',
        content: '记一条',
        localTime: '2026-09-15T10:00:00+08:00',
        timezone: 'Asia/Shanghai');
    return stream.toList();
  }

  test('整段到达：delta、draft、done 依次产出', () async {
    const body = 'data: {"type":"delta","text":"你好"}\n\n'
        'data: {"type":"draft","draft":{"title":"购","content":"牛奶","category_id":1}}\n\n'
        'data: {"type":"done","awaiting_input":true}\n\n';
    final events = await collect(MockClient.streaming((req, bodyStream) async {
      await bodyStream.toBytes();
      return sse([bytes(body)]);
    }));

    expect(events, hasLength(3));
    expect((events[0] as AgentDeltaEvent).text, '你好');
    final draft = (events[1] as AgentDraftEvent).draft;
    expect(draft.title, '购');
    expect(draft.content, '牛奶');
    expect(draft.categoryId, 1);
    expect(draft.remindAt, isNull);
    expect(draft.remindRule, isNull);
    expect((events[2] as AgentDoneEvent).awaitingInput, isTrue);
  });

  test('任意字节处切片（含 UTF-8 字符中间）解析不变', () async {
    final bytesAll = bytes(
        'data: {"type":"delta","text":"你好"}\n\ndata: {"type":"done","awaiting_input":false}\n\n');
    // Cut inside 你's three UTF-8 bytes.
    final cut = bytesAll.indexOf(bytes('你')[0]) + 1;
    final events = await collect(MockClient.streaming((req, bodyStream) async {
      await bodyStream.toBytes();
      return sse([bytesAll.sublist(0, cut), bytesAll.sublist(cut)]);
    }));

    expect(events, hasLength(2));
    expect((events[0] as AgentDeltaEvent).text, '你好');
    expect((events[1] as AgentDoneEvent).awaitingInput, isFalse);
  });

  test('error 帧产出 AgentErrorEvent，message 与 code 原样透出', () async {
    final events = await collect(MockClient.streaming((req, bodyStream) async {
      await bodyStream.toBytes();
      return sse([
        bytes('data: {"type":"error","code":"not_configured","message":"智能体尚未配置，请联系管理员在 Web Console 中完成 AI 设置"}\n\n')
      ]);
    }));

    expect(events, hasLength(1));
    final event = events[0] as AgentErrorEvent;
    expect(event.message, contains('智能体尚未配置'));
    expect(event.code, 'not_configured');
  });

  test('旧式 error 帧（无 code）回退为 internal', () async {
    final events = await collect(MockClient.streaming((req, bodyStream) async {
      await bodyStream.toBytes();
      return sse([
        bytes('data: {"type":"error","message":"回复生成失败"}\n\n')
      ]);
    }));

    expect((events[0] as AgentErrorEvent).code, 'internal');
  });

  test('draft 帧带提醒：remind_at 与 remind_rule 解码', () async {
    final events = await collect(MockClient.streaming((req, bodyStream) async {
      await bodyStream.toBytes();
      return sse([
        bytes('data: {"type":"draft","draft":{"title":"购","content":"","category_id":2,'
            '"remind_at":"2026-09-16T09:00:00+08:00",'
            '"remind_rule":{"mode":"daily","interval":1,"hour":9,"minute":0}}}\n\n')
      ]);
    }));

    final draft = (events[0] as AgentDraftEvent).draft;
    expect(draft.remindAt, DateTime.parse('2026-09-16T09:00:00+08:00').toLocal());
    expect(draft.remindRule!.mode, ReminderMode.daily);
    expect(draft.remindRule!.hour, 9);
  });

  test('SSE 之前的 JSON 错误（校验失败）抛 ApiException', () async {
    await expectLater(
      collect(MockClient.streaming((req, bodyStream) async {
        await bodyStream.toBytes();
        return http.StreamedResponse(
          Stream.value(Uint8List.fromList(utf8.encode('{"error":"invalid_request"}'))),
          400,
          headers: {'content-type': 'application/json'},
        );
      })),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 400)
          .having((e) => e.code, 'code', 'invalid_request')),
    );
  });

  test('请求体形状：content、local_time、timezone 逐字送出', () async {
    Object? captured;
    await collect(MockClient.streaming((req, bodyStream) async {
      captured = jsonDecode(utf8.decode(await bodyStream.toBytes()));
      return sse([bytes('data: {"type":"done","awaiting_input":false}\n\n')]);
    }));

    expect(captured, {
      'content': '记一条',
      'local_time': '2026-09-15T10:00:00+08:00',
      'timezone': 'Asia/Shanghai',
    });
  });

  test('GET agentMessages：展示记录（含草稿行）解码', () async {
    http.Request? captured;
    final api =
        MeridianApi(baseUrl: 'http://fake.meridian.local', client: MockClient(
      (req) async {
        captured = req;
        return http.Response(
            jsonEncode({
              'messages': [
                {'id': 1, 'role': 'user', 'content': '记一条', 'awaiting_input': false, 'created_at': 'x'},
                {
                  'id': 2,
                  'role': 'assistant',
                  'content': '好的',
                  'awaiting_input': true,
                  'created_at': 'y',
                  'draft': {'title': '购', 'content': '牛奶', 'category_id': 1},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'});
      },
    ));

    final messages = await api.agentMessages('t');

    expect(captured!.method, 'GET');
    expect(captured!.url.path, '/api/v1/agent/messages');
    expect(captured!.headers['Authorization'], 'Bearer t');
    expect(messages, hasLength(2));
    expect(messages[0].role, 'user');
    expect(messages[0].draft, isNull);
    expect(messages[1].content, '好的');
    expect(messages[1].awaitingInput, isTrue);
    expect(messages[1].draft!.title, '购');
  });

  test('clearAgentMessages：DELETE /api/v1/agent/messages，204 通过', () async {
    http.Request? captured;
    final api =
        MeridianApi(baseUrl: 'http://fake.meridian.local', client: MockClient(
      (req) async {
        captured = req;
        return http.Response('', 204);
      },
    ));

    await api.clearAgentMessages('t');

    expect(captured!.method, 'DELETE');
    expect(captured!.url.path, '/api/v1/agent/messages');
  });

  test('rfc3339Local：本地墙上时间加数字偏移，服务端可原样解析', () async {
    final t = DateTime(2026, 9, 15, 10, 30, 5);
    final text = rfc3339Local(t);

    expect(
      text,
      matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$')),
    );
    // The wall-clock components survive verbatim, and the offset the string
    // carries decodes back to the same instant.
    expect(text.substring(0, 19), '2026-09-15T10:30:05');
    final off = t.timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    String two(int n) => n.toString().padLeft(2, '0');
    expect(
      text.substring(19),
      '$sign${two(off.inHours.abs())}:${two(off.inMinutes.abs() % 60)}',
    );
  });
}
