import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/app.dart';
import 'package:meridian/server_address_store.dart';
import 'package:meridian/token_store.dart';

import 'fake_meridian_server.dart';

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
}
