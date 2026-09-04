import 'package:flutter/material.dart';

import '../api_client.dart';
import '../editor/meridian_editor.dart';

/// The offline reader (T8): a cached memo opened without a server — title,
/// tags, and a read-only body. Nothing here writes or fetches; editing only
/// happens online, in MemoEditScreen.
class MemoViewScreen extends StatefulWidget {
  final Memo memo;

  const MemoViewScreen({super.key, required this.memo});

  @override
  State<MemoViewScreen> createState() => _MemoViewScreenState();
}

class _MemoViewScreenState extends State<MemoViewScreen> {
  // Parses the cached Markdown once; rendered through the read-only
  // document surface, never through the editor.
  late final MeridianEditorController _body =
      MeridianEditorController(widget.memo.body);

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final memo = widget.memo;
    return Scaffold(
      appBar: AppBar(title: const Text('查看备忘录')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(memo.title, style: Theme.of(context).textTheme.headlineSmall),
            if (memo.tags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final t in memo.tags)
                    Chip(key: Key('tag_chip_$t'), label: Text(t)),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: MeridianDocumentReader(
                key: const Key('body_readonly'),
                controller: _body,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
