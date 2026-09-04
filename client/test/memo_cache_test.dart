import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meridian/api_client.dart';
import 'package:meridian/memo_cache.dart';

/// In-memory fake of the platform secure storage, standing in for the
/// Windows/Android keystore-backed store the same way FakeMeridianServer
/// stands in for the HTTP API.
class FakeSecurePlatform extends FlutterSecureStoragePlatform {
  final Map<String, String> values = {};

  @override
  Future<void> write(
          {required String key,
          required String value,
          required Map<String, String> options}) async =>
      values[key] = value;

  @override
  Future<String?> read(
          {required String key,
          required Map<String, String> options}) async =>
      values[key];

  @override
  Future<bool> containsKey(
          {required String key,
          required Map<String, String> options}) async =>
      values.containsKey(key);

  @override
  Future<void> delete(
          {required String key,
          required Map<String, String> options}) async =>
      values.remove(key);

  @override
  Future<Map<String, String>> readAll(
          {required Map<String, String> options}) async =>
      Map.of(values);

  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      values.clear();
}

CachedSnapshot sampleSnapshot() => CachedSnapshot(
      token: 'fake-token-yifeng-1',
      memos: [
        Memo(
            id: 7,
            title: '购物清单',
            body: '牛奶、鸡蛋',
            categoryId: 2,
            tags: const ['英语', '单词']),
      ],
      categories: [
        Category(id: 1, name: '未分类', isBuiltin: true),
        Category(id: 2, name: '工作', isBuiltin: false),
      ],
    );

void main() {
  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecurePlatform();
  });

  test('快照写入安全存储后可原样读回（跨重启的持久化）', () async {
    final snapshot = sampleSnapshot();
    await SecureMemoCache().write(snapshot);

    // A fresh cache over the same storage stands in for the app restarting.
    final readBack = (await SecureMemoCache().read())!;
    expect(readBack.token, snapshot.token);
    expect(readBack.memos.single.title, '购物清单');
    expect(readBack.memos.single.body, '牛奶、鸡蛋');
    expect(readBack.memos.single.categoryId, 2);
    expect(readBack.memos.single.tags, ['英语', '单词']);
    expect(readBack.categories[0].name, '未分类');
    expect(readBack.categories[0].isBuiltin, isTrue);
    expect(readBack.categories[1].name, '工作');
    expect(readBack.categories[1].isBuiltin, isFalse);
  });

  test('损坏的缓存读作没有缓存，不让应用崩溃', () async {
    await SecureMemoCache().write(sampleSnapshot());
    // Storage corrupted between runs (or written by another version).
    (FlutterSecureStoragePlatform.instance as FakeSecurePlatform)
        .values['meridian_offline_snapshot'] = 'not json at all';
    expect(await SecureMemoCache().read(), isNull);
  });

  test('clear 之后读不到任何快照', () async {
    await SecureMemoCache().write(sampleSnapshot());
    await SecureMemoCache().clear();
    expect(await SecureMemoCache().read(), isNull);
  });
}
