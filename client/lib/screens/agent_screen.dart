import 'package:flutter/material.dart';

/// The 智能体 page (#71). This ticket only stands up the navigation shell,
/// so the page is the explicit empty state for an agent that is not usable
/// yet — the instance's AI 设置 is not configured. Ticket #76 replaces this
/// file wholesale with the real conversation page; nothing else hangs off
/// this screen.
class AgentScreen extends StatelessWidget {
  const AgentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('智能体')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 48, color: colors.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('智能体尚未配置', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '请联系管理员在 Web 管理控制台完成 AI 设置',
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
