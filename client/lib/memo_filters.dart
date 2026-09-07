import 'api_client.dart';

/// The three ways the memo list narrows (T4 tag, T14 category, T6 query),
/// traveling as one bundle: the load asks the server for all of them at
/// once, and while any of them stands the page shows a subset rather than
/// the whole truth — so no snapshot write, no scheduler sync, no quiet
/// reminder poll.
class MemoFilters {
  final String? tag;
  final Category? category;
  final String? query;

  const MemoFilters({this.tag, this.category, this.query});

  /// True while any filter stands.
  bool get isFiltered => tag != null || category != null || query != null;
}
