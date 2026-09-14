import 'package:flutter/material.dart';

/// The 搜索 page placeholder (#71): this ticket only stands up the
/// navigation shell, so the page says it is on its way — full-text search
/// still lives in the home app bar until #72 replaces this file with the
/// real search page.
class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('搜索')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search, size: 48, color: colors.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('搜索页建设中', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '全文搜索仍在首页，敬请期待',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
