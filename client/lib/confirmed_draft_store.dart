import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One entry of the device-local 已确认草稿集合: the conversation message id
/// of a draft row the user confirmed on this device, and the id of the memo
/// that confirmation created. Plain ints, both server-assigned.
class ConfirmedDraft {
  final int messageId;
  final int memoId;

  const ConfirmedDraft({required this.messageId, required this.memoId});

  Map<String, dynamic> toJson() =>
      {'message_id': messageId, 'memo_id': memoId};

  factory ConfirmedDraft.fromJson(Map<String, dynamic> json) => ConfirmedDraft(
        messageId: json['message_id'] as int,
        memoId: json['memo_id'] as int,
      );
}

/// Where the client remembers which draft cards it already confirmed (#76):
/// a restored conversation renders those rows as created — with a way in —
/// instead of offering a second confirmation and a second memo. Client-local
/// only, like every other record of a Draft confirmation: the server keeps
/// none, so another device still shows the card as pending, where confirming
/// again amounts to re-entering the memo by hand. Platform secure storage in
/// production, in-memory in tests.
abstract class ConfirmedDraftStore {
  Future<List<ConfirmedDraft>> read();
  Future<void> write(List<ConfirmedDraft> entries);
  Future<void> clear();
}

class SecureConfirmedDraftStore implements ConfirmedDraftStore {
  static const _key = 'meridian_confirmed_drafts';
  final FlutterSecureStorage _storage;

  SecureConfirmedDraftStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<List<ConfirmedDraft>> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return const [];
    try {
      return [
        for (final entry in jsonDecode(raw) as List)
          ConfirmedDraft.fromJson(entry as Map<String, dynamic>),
      ];
    } catch (_) {
      // A garbled entry must never keep the chat from opening.
      return const [];
    }
  }

  @override
  Future<void> write(List<ConfirmedDraft> entries) => _storage.write(
      key: _key,
      value: jsonEncode([for (final entry in entries) entry.toJson()]));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class InMemoryConfirmedDraftStore implements ConfirmedDraftStore {
  List<ConfirmedDraft> _entries = const [];

  @override
  Future<List<ConfirmedDraft>> read() async => _entries;

  @override
  Future<void> write(List<ConfirmedDraft> entries) async =>
      _entries = List.of(entries);

  @override
  Future<void> clear() async => _entries = const [];
}
