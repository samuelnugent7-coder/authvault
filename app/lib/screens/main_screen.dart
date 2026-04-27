import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../config/app_config.dart';
import 'login_screen.dart';
import 'totp/totp_screen.dart';
import 'safe/safe_screen.dart';
import 'settings_screen.dart';
import 'backup_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _tab = 0;

  final _pages = const [
    TotpScreen(),
    SafeScreen(),
    BackupScreen(),
    SettingsScreen(),
  ];

  Future<void> _logout() async {
    final api = context.read<ApiService>();
    await api.logout();
    await AppConfig.clearToken();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AuthVault'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Lock & Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: _pages[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.lock_clock), label: 'Authenticator'),
          NavigationDestination(icon: Icon(Icons.folder_special), label: 'Password Safe'),
          NavigationDestination(icon: Icon(Icons.backup), label: 'Backup'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}
