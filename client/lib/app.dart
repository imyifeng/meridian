import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'memo_cache.dart';
import 'reminders.dart';
import 'screens/login_screen.dart';
import 'screens/memos_screen.dart';
import 'screens/setup_screen.dart';
import 'server_address_store.dart';
import 'session.dart';
import 'theme.dart';
import 'token_store.dart';

enum AppState { loading, setup, login, memos }

/// MeridianApp wires the server address, the credential store, and the
/// screen flow: setup wizard on an uninitialized instance, otherwise
/// login (skipped when a stored credential still works), then memos. When
/// the server is unreachable but a cached snapshot for the stored
/// credential exists, it still enters the memos — read-only (ADR-0003);
/// with no usable snapshot it lands on the login screen, where the server
/// address is editable (a fresh install's default points at the device
/// itself, so editing it is the only way to reach the instance).
class MeridianApp extends StatefulWidget {
  final String baseUrl;
  final TokenStore tokenStore;

  /// Offline snapshot store (T8); production persists via
  /// shared_preferences, tests leave it null for the in-memory cache.
  final MemoCache? memoCache;

  /// Where the last-used server address persists between launches (T11);
  /// production persists via platform secure storage, tests leave it null
  /// for the in-memory store. When it holds an address, it beats the
  /// compile-time [baseUrl] on the next launch.
  final ServerAddressStore? addressStore;

  /// Transport override for UI seam tests; production uses the default
  /// socket-based client.
  final http.Client? apiClient;

  /// The platform notification surface for reminders (T9); tests inject a
  /// fake, production the plugin adapter. Null disables reminder scheduling
  /// entirely — the Web 简易客户端 carries no reminder notifications.
  final ReminderNotifications? reminderNotifications;

  /// Clock override for reminder scheduling tests.
  final DateTime Function()? reminderNow;

  /// The Web 简易客户端 mode (T10): the build is served by the instance
  /// itself, so the API is same-origin and no server-address field is
  /// offered — and reminders, a 客户端 feature, get no editing entry
  /// points on the web.
  final bool webClient;

  const MeridianApp({
    super.key,
    required this.baseUrl,
    required this.tokenStore,
    this.memoCache,
    this.addressStore,
    this.apiClient,
    this.reminderNotifications,
    this.reminderNow,
    this.webClient = false,
  });

  @override
  State<MeridianApp> createState() => _MeridianAppState();
}

class _MeridianAppState extends State<MeridianApp> {
  late final TextEditingController _serverAddress;
  late final MemoCache _memoCache;
  late final ServerAddressStore _addressStore;
  AppState _state = AppState.loading;
  // The signed-in stretch's api-plus-credential (see MeridianSession):
  // built once the credential is proven, dropped at sign-out.
  MeridianSession? _session;
  // True once the app entered the memos on a cached snapshot because the
  // server was unreachable (T8); MemosScreen takes it from there.
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _serverAddress = TextEditingController(text: widget.baseUrl);
    _memoCache = widget.memoCache ?? InMemoryMemoCache();
    _addressStore = widget.addressStore ?? InMemoryServerAddressStore();
    _bootstrap();
  }

  @override
  void dispose() {
    _serverAddress.dispose();
    super.dispose();
  }

  MeridianApi _api() =>
      MeridianApi(baseUrl: _serverAddress.text.trim(), client: widget.apiClient);

  Future<void> _bootstrap() async {
    setState(() => _state = AppState.loading);
    // The address the user last logged in with beats the compile-time
    // default (T11).
    final stored = (await _addressStore.read())?.trim();
    if (stored != null && stored.isNotEmpty) {
      _serverAddress.text = stored;
    }
    String? token = await widget.tokenStore.read();
    try {
      final initialized = await _api().isInitialized();
      if (!initialized) {
        setState(() => _state = AppState.setup);
        return;
      }
      if (token == null) {
        setState(() => _state = AppState.login);
        return;
      }
      await _api().memos(token); // prove the stored credential still works
      setState(() {
        _session = MeridianSession(api: _api(), token: token);
        _offline = false;
        _state = AppState.memos;
      });
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        // The credential is dead, so its cached snapshot must not linger.
        await widget.tokenStore.clear();
        await _memoCache.clear();
        setState(() => _state = AppState.login);
      } else {
        // Offline with a cache for this credential (ADR-0003): read-only
        // memos beat the login page. MemosScreen keeps retrying until the
        // connection returns. Without a usable snapshot — fresh install,
        // none for this credential — the login screen is the way out: its
        // address field carries the just-tried address, so the user can
        // aim at the real instance instead of retrying a dead one.
        final snapshot =
            e.isUnreachable && token != null
                ? await _snapshotForToken(token)
                : null;
        if (snapshot != null) {
          setState(() {
            _session = MeridianSession(api: _api(), token: snapshot.token);
            _offline = true;
            _state = AppState.memos;
          });
        } else {
          setState(() => _state = AppState.login);
        }
      }
    }
  }

  /// The cached snapshot, but only if it belongs to [token] — another
  /// user's memos must never be shown.
  Future<CachedSnapshot?> _snapshotForToken(String token) async {
    final snapshot = await _memoCache.read();
    return snapshot?.token == token ? snapshot : null;
  }

  Future<void> _authenticated(Session session) async {
    // The address just proven to work is the one to bring back next launch.
    await _addressStore.write(_serverAddress.text.trim());
    await widget.tokenStore.write(session.token);
    setState(() {
      _session = MeridianSession(api: _api(), token: session.token);
      _state = AppState.memos;
    });
  }

  void _signedOut() {
    widget.tokenStore.clear();
    // Signed out means the local memo cache goes too: the next user of this
    // device must not read the previous one's memos offline.
    _memoCache.clear();
    setState(() {
      _session = null;
      _offline = false;
      _state = AppState.login;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Dark mode follows the system only (ADR-0007): both palettes come from
    // the shared MD3 theme file, keyed to the platform's brightness.
    return MaterialApp(
      title: 'Meridian',
      theme: meridianLightTheme,
      darkTheme: meridianDarkTheme,
      themeMode: ThemeMode.system,
      home: switch (_state) {
        AppState.loading => const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
        AppState.setup => SetupScreen(
            serverAddress: _serverAddress,
            api: _api,
            showServerAddress: !widget.webClient,
            onAuthenticated: _authenticated,
            onAlreadyInitialized: () => setState(() => _state = AppState.login),
          ),
        AppState.login => LoginScreen(
            serverAddress: _serverAddress,
            api: _api,
            showServerAddress: !widget.webClient,
            onAuthenticated: _authenticated,
          ),
        AppState.memos => MemosScreen(
            session: _session!,
            cache: _memoCache,
            initialOffline: _offline,
            reminderNotifications: widget.reminderNotifications,
            reminderNow: widget.reminderNow,
            showReminder: !widget.webClient,
            onSignOut: _signedOut,
          ),
      },
    );
  }
}
