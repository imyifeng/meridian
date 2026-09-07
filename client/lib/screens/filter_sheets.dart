import 'package:flutter/material.dart';

import '../api_client.dart';
import '../session.dart';

/// Offers the user's own tag history (T4); picking one filters the list.
/// Fetch failures surface as a snack bar; null means nothing was picked.
Future<String?> showTagFilterSheet(
  BuildContext context, {
  required MeridianSession session,
}) async {
  List<String> tags;
  try {
    tags = await session.api.tags(session.token);
  } on ApiException {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载标签失败')));
    }
    return null;
  }
  if (!context.mounted) return null;
  return showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: tags.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Text('还没有用过的标签'),
            )
          : ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final t in tags)
                    ListTile(
                      key: Key('filter_tag_$t'),
                      leading: const Icon(Icons.label_outline),
                      title: Text(t),
                      onTap: () => Navigator.of(context).pop(t),
                    ),
                ],
              ),
            ),
    ),
  );
}

/// Offers the instance taxonomy (ADR-0002); picking one filters the list.
/// 只读的选择，不提供任何增减分类的途径 (ADR-0002)。
/// Fetch failures surface as a snack bar; null means nothing was picked.
Future<Category?> showCategoryFilterSheet(
  BuildContext context, {
  required MeridianSession session,
}) async {
  List<Category> categories;
  try {
    categories = await session.api.categories(session.token);
  } on ApiException {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载分类失败')));
    }
    return null;
  }
  if (!context.mounted) return null;
  return showModalBottomSheet<Category>(
    context: context,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final c in categories)
              ListTile(
                key: Key('filter_category_${c.name}'),
                leading: const Icon(Icons.category_outlined),
                title: Text(c.name),
                onTap: () => Navigator.of(context).pop(c),
              ),
          ],
        ),
      ),
    ),
  );
}
