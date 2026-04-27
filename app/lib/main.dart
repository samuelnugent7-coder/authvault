import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/api_service.dart';
import 'services/backup_scheduler.dart';
import 'services/cache_service.dart';
import 'services/sync_service.dart';
import 'services/vault_manager.dart';
import 'screens/login_screen.dart';
import 'screens/main_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialise vault manager before anything else so AppConfig delegates work.
  await VaultManager.instance.init();
  // Initialise WorkManager for nightly backup (Android only)
  if (Platform.isAndroid) {
    try { await BackupScheduler.scheduleNightly(); } catch (_) {}
  }
  runApp(
    ChangeNotifierProvider<VaultManager>.value(
      value: VaultManager.instance,
      child: Provider<ApiService>(
        create: (_) => ApiService(),
        child: const AuthVaultApp(),
      ),
    ),
  );
}

class AuthVaultApp extends StatelessWidget {
  const AuthVaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AuthVault',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A73E8),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const _Splash(),
    );
  }
}

class _Splash extends StatefulWidget {
  const _Splash();
  @override
  State<_Splash> createState() => _SplashState();
}

class _SplashState extends State<_Splash> {
  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    final token = await VaultManager.instance.getToken();
    if (token != null) {
      CacheService.instance.setKeyFromToken(token);

      bool serverOk = false;
      try {
        final api = context.read<ApiService>();
        serverOk = await api.isServerUnlocked()
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        serverOk = false;
      }

      if (!mounted) return;

      if (serverOk) {
        // Validate JWT and restore user info
        try {
          final api = context.read<ApiService>();
          final me = await api.getMe().timeout(const Duration(seconds: 3));
          if (me == null || me.username.isEmpty) {
            // Stale JWT — force re-login
            await VaultManager.instance.clearToken();
            if (!mounted) return;
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const LoginScreen()),
            );
            return;
          }
          await VaultManager.instance.setUserInfo(me);
        } catch (_) {
          // Can't validate — proceed offline-style
        }
        await SyncService.instance.init();
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const MainScreen()),
        );
        return;
      }

      // Server unreachable — fall back to cached data if available.
      final hasCache = await CacheService.instance.hasCachedData();
      if (!mounted) return;
      if (hasCache) {
        await SyncService.instance.init();
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const MainScreen()),
        );
        return;
      }
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
