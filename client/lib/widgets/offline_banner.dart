import 'package:flutter/material.dart';

/// The offline notice a server-backed list shows (T8, ADR-0003): what still
/// works while the instance is unreachable, under a wifi_off mark. Each
/// screen carries its own key (the IndexedStack mounts every page at once),
/// and the wording states what that screen can and cannot do.
class OfflineBanner extends StatelessWidget {
  final String message;

  const OfflineBanner({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.wifi_off, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
