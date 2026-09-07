import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:meridian/app.dart';
import 'package:meridian/server_address_store.dart';
import 'package:meridian/token_store.dart';

import 'fake_meridian_server.dart';

/// Transport that records every request URL, then delegates to the fake.
/// The fake routes by path and answers any host, so only this layer can
/// tell where a request actually went (#56).
class RecordingClient extends http.BaseClient {
  RecordingClient(this._inner);
  final http.Client _inner;
  final List<Uri> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    return _inner.send(request);
  }
}

void main() {
  testWidgets('登录成功后，填写的服务器地址写入持久存储', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    final addressStore = InMemoryServerAddressStore();

    await tester.pumpWidget(
      MeridianApp(
        baseUrl: 'http://127.0.0.1:8080', // 编译期默认值
        tokenStore: InMemoryTokenStore(),
        addressStore: addressStore,
        apiClient: fake.client,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const Key('server_address_field')), fake.url);
    await tester.enterText(find.byKey(const Key('username_field')), 'yifeng');
    await tester.enterText(
        find.byKey(const Key('password_field')), 'correct horse');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();

    expect(find.text('暂无备忘录'), findsOneWidget); // 登录成功
    expect(await addressStore.read(), fake.url);
  });

  testWidgets('下次启动自动带出上次使用的服务器地址，而非编译期默认值', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    final addressStore = InMemoryServerAddressStore();
    await addressStore.write('http://192.168.1.10:8080');

    // “第二次启动”：编译期默认值仍是 127.0.0.1，但存储的地址应胜出。
    await tester.pumpWidget(
      MeridianApp(
        baseUrl: 'http://127.0.0.1:8080',
        tokenStore: InMemoryTokenStore(),
        addressStore: addressStore,
        apiClient: fake.client,
      ),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
        find.byKey(const Key('server_address_field')));
    expect(field.controller!.text, 'http://192.168.1.10:8080');
  });

  testWidgets('登录失败不保存服务器地址', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    final addressStore = InMemoryServerAddressStore();

    await tester.pumpWidget(
      MeridianApp(
        baseUrl: fake.url,
        tokenStore: InMemoryTokenStore(),
        addressStore: addressStore,
        apiClient: fake.client,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const Key('server_address_field')), 'http://192.168.1.99:1');
    await tester.enterText(find.byKey(const Key('username_field')), 'yifeng');
    await tester.enterText(
        find.byKey(const Key('password_field')), 'wrong');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();

    expect(find.text('用户名或密码错误'), findsOneWidget);
    expect(await addressStore.read(), isNull);
  });

  testWidgets('登录页修改地址后提交，登录请求发往修改后的地址', (tester) async {
    final fake = FakeMeridianServer();
    fake.registerUser('yifeng', 'correct horse');
    final transport = RecordingClient(fake.client);

    // 预填默认地址指向设备自身（手机上的典型开局），fake 的 host 与它不同。
    await tester.pumpWidget(
      MeridianApp(
        baseUrl: 'http://127.0.0.1:8080',
        tokenStore: InMemoryTokenStore(),
        apiClient: transport,
      ),
    );
    await tester.pumpAndSettle();

    // 用户把地址改成另一台机器再登录。
    await tester.enterText(
        find.byKey(const Key('server_address_field')), 'http://10.8.0.6:8080');
    await tester.enterText(find.byKey(const Key('username_field')), 'yifeng');
    await tester.enterText(
        find.byKey(const Key('password_field')), 'correct horse');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();

    // 登录成功进入应用，且登录请求的完整 URL 等于用户输入的地址。
    expect(find.text('暂无备忘录'), findsOneWidget);
    expect(
      transport.requests
          .where((url) => url.path == '/api/v1/auth/login')
          .toList(),
      [Uri.parse('http://10.8.0.6:8080/api/v1/auth/login')],
    );
  });

  testWidgets('初始化向导修改地址后提交，创建管理员请求发往修改后的地址', (tester) async {
    final fake = FakeMeridianServer(); // 未初始化
    final transport = RecordingClient(fake.client);

    await tester.pumpWidget(
      MeridianApp(
        baseUrl: 'http://127.0.0.1:8080',
        tokenStore: InMemoryTokenStore(),
        apiClient: transport,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('create_administrator_button')), findsOneWidget);

    await tester.enterText(
        find.byKey(const Key('server_address_field')), 'http://10.8.0.6:8080');
    await tester.enterText(find.byKey(const Key('username_field')), 'boss');
    await tester.enterText(
        find.byKey(const Key('password_field')), 'first password');
    await tester.tap(find.byKey(const Key('create_administrator_button')));
    await tester.pumpAndSettle();

    // 向导完成直接进入应用，创建管理员请求的完整 URL 等于用户输入的地址。
    expect(find.text('暂无备忘录'), findsOneWidget);
    expect(
      transport.requests
          .where((url) => url.path == '/api/v1/setup/administrator')
          .toList(),
      [Uri.parse('http://10.8.0.6:8080/api/v1/setup/administrator')],
    );
  });
}
