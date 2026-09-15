import 'package:flutter/material.dart';

import '../confirmed_draft_store.dart';
import '../memo_cache.dart';
import '../reminders.dart';
import '../session.dart';
import 'agent_screen.dart';
import 'memos_screen.dart';
import 'profile_screen.dart';
import 'search_screen.dart';

/// One top-level destination of the shell (#71): its icons and its label.
class _Tab {
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  const _Tab(this.icon, this.selectedIcon, this.label);
}

const List<_Tab> _tabs = [
  _Tab(Icons.home_outlined, Icons.home, '首页'),
  _Tab(Icons.chat_bubble_outline, Icons.chat_bubble, '智能体'),
  _Tab(Icons.search_outlined, Icons.search, '搜索'),
  _Tab(Icons.person_outline, Icons.person, '我的'),
];

/// The Windows/Android 客户端's navigation shell (#71): the four top-level
/// pages — 首页 (the memo list, unchanged), 智能体, 搜索, 我的 — behind a
/// bottom NavigationBar, stacked in an IndexedStack so each tab keeps its
/// state while another is on show. The Web 简易客户端 never mounts this
/// shell: it keeps its single-page MemosScreen layout and the Web Console
/// is untouched.
class HomeShell extends StatefulWidget {
  final MeridianSession session;
  final MemoCache cache;

  /// Booted without a reachable server on a cached snapshot (ADR-0003);
  /// home starts read-only until a retry succeeds.
  final bool initialOffline;

  /// The 智能体's device-local 已确认草稿集合 (#76 review).
  final ConfirmedDraftStore confirmedDraftStore;

  /// The platform notification surface (T9); home owns the scheduling.
  final ReminderNotifications? reminderNotifications;

  /// Clock override for reminder tests; production uses the wall clock.
  final DateTime Function()? reminderNow;

  final VoidCallback onSignOut;

  /// The theme preference in force (ADR-0010), owned by the app and shown
  /// on the 我的 page; the shell only passes it through.
  final ThemeMode themeMode;

  final ValueChanged<ThemeMode> onThemeModeChanged;

  const HomeShell({
    super.key,
    required this.session,
    required this.cache,
    this.initialOffline = false,
    required this.confirmedDraftStore,
    this.reminderNotifications,
    this.reminderNow,
    required this.onSignOut,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  /// The MD3 canonical expanded width: from here up the bottom bar gives
  /// way to a side rail.
  static const double _expandedBreakpoint = 840;

  void _select(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    // One IndexedStack for both layouts: every tab stays alive (home keeps
    // its list, scroll position, and reminder sync) while another is shown.
    final stack = IndexedStack(
      index: _index,
      children: [
        MemosScreen(
          session: session,
          cache: widget.cache,
          initialOffline: widget.initialOffline,
          reminderNotifications: widget.reminderNotifications,
          reminderNow: widget.reminderNow,
          // Sign-out lives on the 我的 page in the shell (#71), and search
          // on the 搜索 page (#72).
          showLogout: false,
          showSearch: false,
          onSignOut: widget.onSignOut,
        ),
        AgentScreen(
          session: session,
          initialOffline: widget.initialOffline,
          confirmedDraftStore: widget.confirmedDraftStore,
          onSignOut: widget.onSignOut,
        ),
        SearchScreen(
          session: session,
          cache: widget.cache,
          initialOffline: widget.initialOffline,
          onSignOut: widget.onSignOut,
        ),
        ProfileScreen(
          user: session.user,
          onSignOut: widget.onSignOut,
          themeMode: widget.themeMode,
          onThemeModeChanged: widget.onThemeModeChanged,
        ),
      ],
    );
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth >= _expandedBreakpoint) {
        return Scaffold(
          body: Row(
            children: [
              NavigationRail(
                key: const Key('nav_rail'),
                selectedIndex: _index,
                onDestinationSelected: _select,
                labelType: NavigationRailLabelType.all,
                destinations: [
                  for (final tab in _tabs)
                    NavigationRailDestination(
                      icon: Icon(tab.icon),
                      selectedIcon: Icon(tab.selectedIcon),
                      label: Text(tab.label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(child: stack),
            ],
          ),
        );
      }
      return Scaffold(
        body: stack,
        bottomNavigationBar: NavigationBar(
          key: const Key('nav_bar'),
          selectedIndex: _index,
          onDestinationSelected: _select,
          destinations: [
            for (final tab in _tabs)
              NavigationDestination(
                icon: Icon(tab.icon),
                selectedIcon: Icon(tab.selectedIcon),
                label: tab.label,
              ),
          ],
        ),
      );
    });
  }
}
