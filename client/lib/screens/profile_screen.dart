import 'package:flutter/material.dart';

import '../api_client.dart';

/// The 我的 page (#71): the signed-in account — username and role — plus
/// the settings area and the sign-out entry, which reuses the app's
/// existing sign-out path. The settings area carries the theme three-state
/// switch (ADR-0010): 深色, 浅色, 跟随系统 — the default. The preference is
/// client-local (ThemeModeStore), never account data.
class ProfileScreen extends StatelessWidget {
  /// The signed-in user; null only when the app resumed from a stored
  /// credential whose owner the client never learned (e.g. a pre-upgrade
  /// install) — the page degrades to unknown rather than inventing data.
  final User? user;

  final VoidCallback onSignOut;

  /// The theme preference in force, owned by the app state.
  final ThemeMode themeMode;

  final ValueChanged<ThemeMode> onThemeModeChanged;

  const ProfileScreen({
    super.key,
    this.user,
    required this.onSignOut,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final user = this.user;
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  child: const Icon(Icons.person, size: 32),
                ),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(user?.username ?? '未知账号',
                        style: Theme.of(context).textTheme.titleLarge),
                    if (user != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        // Same wording the Web Console uses for the role.
                        user.isAdministrator ? '管理员' : '用户',
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const Divider(indent: 16, endIndent: 16),
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 8, bottom: 8),
            child: Text('设置',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.primary)),
          ),
          // 主题三态 (ADR-0010): one radio per state, grouped by RadioGroup;
          // the app applies and persists the choice the moment one is picked.
          ListTile(
            title: Text('主题', style: Theme.of(context).textTheme.bodyLarge),
          ),
          RadioGroup<ThemeMode>(
            groupValue: themeMode,
            onChanged: (mode) => onThemeModeChanged(mode!),
            child: Column(
              children: [
                RadioListTile<ThemeMode>(
                  key: const Key('theme_mode_dark'),
                  title: const Text('深色'),
                  value: ThemeMode.dark,
                ),
                RadioListTile<ThemeMode>(
                  key: const Key('theme_mode_light'),
                  title: const Text('浅色'),
                  value: ThemeMode.light,
                ),
                RadioListTile<ThemeMode>(
                  key: const Key('theme_mode_system'),
                  title: const Text('跟随系统'),
                  value: ThemeMode.system,
                ),
              ],
            ),
          ),
          const Divider(indent: 16, endIndent: 16),
          // The app's one sign-out entry point (#71): it moved here from the
          // home app bar and calls the same app-level sign-out path.
          ListTile(
            key: const Key('sign_out_button'),
            leading: const Icon(Icons.logout),
            title: const Text('退出登录'),
            onTap: onSignOut,
          ),
        ],
      ),
    );
  }
}
