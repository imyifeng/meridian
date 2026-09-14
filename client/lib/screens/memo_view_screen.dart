import 'package:flutter/material.dart';

import '../api_client.dart';
import '../recurrence.dart';
import '../reminders.dart';

/// The offline reader (T8): a cached memo opened without a server — title,
/// tags, and the body shown literally (ADR-0008). Nothing here writes or
/// fetches; editing only happens online, in MemoEditScreen.
class MemoViewScreen extends StatelessWidget {
  final Memo memo;

  const MemoViewScreen({super.key, required this.memo});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('查看备忘录')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(memo.title, style: Theme.of(context).textTheme.headlineSmall),
            if (memo.remindAt != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.alarm, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    // A recurring reminder (T70) names its rule and the
                    // next trigger time point; a one-shot names its time.
                    '提醒：${memo.remindRule == null ? formatReminder(memo.remindAt!) : '${describeRecurrence(memo.remindRule!)} · 下次 ${formatReminder(memo.remindAt!)}'}',
                    key: const Key('reminder_value'),
                  ),
                ],
              ),
            ],
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
            // Plain-text body (ADR-0008): rendered verbatim, Markdown
            // symbols and all. Scrollable so a long body stays reachable
            // instead of being clipped, inside a SelectionArea so it can
            // still be copied.
            Expanded(
              child: SelectionArea(
                child: SingleChildScrollView(
                  child: Text(
                    memo.body,
                    key: const Key('body_readonly'),
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
