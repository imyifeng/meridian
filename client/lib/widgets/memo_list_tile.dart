import 'package:flutter/material.dart';

import '../api_client.dart';

/// One row of a memo list: the title, the plain-text body as a one-line
/// preview (ADR-0008), and the trailing reminder mark (T9) plus the
/// taxonomy category the memo lives in (ADR-0002). Shared by the home list
/// and the 搜索 page's results; what a tap does stays with the screen.
class MemoListTile extends StatelessWidget {
  final Memo memo;

  /// The taxonomy names the row's category label comes from.
  final Map<int, String> categoryNames;

  final VoidCallback onTap;

  const MemoListTile({
    super.key,
    required this.memo,
    required this.categoryNames,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // The preview is the plain-text body itself (ADR-0008), clipped to
    // one line by the row — no conversion of any kind.
    final preview = memo.body;
    return ListTile(
      title: Text(memo.title),
      subtitle: preview.isEmpty
          ? null
          : Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
      // The alarm marks a memo carrying a reminder (T9) — one set on any
      // device shows up on every list, because it rode along with the memo.
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (memo.remindAt != null) ...[
          const Icon(Icons.alarm, size: 16),
          const SizedBox(width: 6),
        ],
        Text(categoryNames[memo.categoryId] ?? ''),
      ]),
      onTap: onTap,
    );
  }
}
