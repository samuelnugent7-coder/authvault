import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'models/user_info.dart';
import 'services/api_service.dart';
import 'services/vault_manager.dart';
import 'services/cache_service.dart';
import 'services/sync_service.dart';
import 'screens/login_screen.dart';
import 'screens/main_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await VaultManager.instance.init();
  await windowManager.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.setTitle('AuthVault');
    await windowManager.setMinimumSize(const Size(900, 600));
    await windowManager.setSize(const Size(1200, 750));
    await windowManager.center();
    await windowManager.show();
  }

  runApp(const AuthVaultApp());
}

class AuthVaultApp extends StatelessWidget {
  const AuthVaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        ChangeNotifierProvider<VaultManager>.value(value: VaultManager.instance),
      ],
      child: MaterialApp(
        title: 'AuthVault',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1A73E8),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const AppRouter(),
      ),
    );
  }
}

class AppState extends ChangeNotifier {
  bool _loggedIn = false;
  bool get loggedIn => _loggedIn;
  String _username = 'admin';
  bool _isAdmin = false;
  String get username => _username;
  bool get isAdmin => _isAdmin;

  void loginAs(UserInfo info) {
    _loggedIn = true;
    _username = info.username;
    _isAdmin = info.isAdmin;
    notifyListeners();
  }

  // legacy compat — kept for AppRouter offline path
  void login() {
    _loggedIn = true;
    notifyListeners();
  }

  void logout() {
    _loggedIn = false;
    _username = 'admin';
    _isAdmin = false;
    notifyListeners();
  }
}

/// Checks for a stored token on startup and skips the login screen if valid.
class AppRouter extends StatefulWidget {
  const AppRouter({super.key});

  @override
  State<AppRouter> createState() => _AppRouterState();
}

class _AppRouterState extends State<AppRouter> {
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _checkStoredToken();
  }

  Future<void> _checkStoredToken() async {
    try {
      final token = await VaultManager.instance.getToken();
      if (token != null && token.isNotEmpty) {
        CacheService.instance.setKeyFromToken(token);
        bool unlocked = false;
        try {
          unlocked = await ApiService().isServerUnlocked()
              .timeout(const Duration(seconds: 5));
        } catch (_) {}
        if (unlocked && mounted) {
          try {
            final me = await ApiService().getMe()
                .timeout(const Duration(seconds: 5));
            // If JWT is stale (no username claim), force re-login
            if (me == null || me.username.isEmpty) {
              await VaultManager.instance.clearToken();
              return; // show login screen
            }
            await VaultManager.instance.setUserInfo(me);
            await SyncService.instance.init();
            if (mounted) context.read<AppState>().loginAs(me);
          } catch (_) {
            // getMe failed — stale token or network error, force re-login
            await VaultManager.instance.clearToken();
          }
          return;
        }
        // Offline fallback: use cache if available
        if (await CacheService.instance.hasCachedData() && mounted) {
          // Try to restore user info from stored prefs
          final uname = VaultManager.instance.username;
          final admin = VaultManager.instance.isAdmin;
          if (uname.isNotEmpty) {
            final info = UserInfo(
              username: uname,
              isAdmin: admin,
              perms: admin
                  ? UserPermissions.adminAll()
                  : const UserPermissions(
                      totp: ResourcePerms(),
                      safe: ResourcePerms(),
                      backup: ResourcePerms()),
            );
            if (mounted) context.read<AppState>().loginAs(info);
          } else {
            if (mounted) context.read<AppState>().login();
          }
        }
      }
    } catch (_) {
      // Any error → show login screen
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Consumer<AppState>(
      builder: (_, state, __) =>
          state.loggedIn ? const MainScreen() : const LoginScreen(),
    );
  }
}
