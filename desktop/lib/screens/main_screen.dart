import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../services/sync_service.dart';
import 'totp/totp_screen.dart';
import 'safe/safe_screen.dart';
import 'settings_screen.dart';
import 'backup/backup_screen.dart';
import 'admin_screen.dart';
import 'audit_screen.dart';
import 'sessions_screen.dart';
import 'health_screen.dart';
import 'ssh_screen.dart';
import 'snapshot_screen.dart';
import 'dashboard_screen.dart';
import 'generator_screen.dart';
import 'recycle_bin_screen.dart';
import 'notes_screen.dart';
import 'tags_screen.dart';
import 'share_links_screen.dart';
import 'api_keys_screen.dart';
import 'csv_import_screen.dart';
import 'integrity_screen.dart';
import 'email_config_screen.dart';
import 'duress_admin_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;

  static const _coreNavItems = [
    _NavDef(Icons.dashboard_outlined,   Icons.dashboard,           'Dashboard'),
    _NavDef(Icons.access_time_outlined, Icons.access_time_filled,  'Authenticator'),
    _NavDef(Icons.shield_outlined,      Icons.shield,              'Password Safe'),
    _NavDef(Icons.sticky_note_2_outlined, Icons.sticky_note_2,    'Secure Notes'),
    _NavDef(Icons.label_outlined,       Icons.label,               'Tags'),
    _NavDef(Icons.casino_outlined,      Icons.casino,              'Generator'),
    _NavDef(Icons.upload_file_outlined, Icons.upload_file,         'CSV Import'),
    _NavDef(Icons.settings_outlined,    Icons.settings,            'Settings'),
    _NavDef(Icons.backup_outlined,      Icons.backup,              'Backup'),
    _NavDef(Icons.health_and_safety_outlined, Icons.health_and_safety, 'Password Health'),
    _NavDef(Icons.key_outlined,         Icons.key,                 'SSH Keys'),
    _NavDef(Icons.devices_outlined,     Icons.devices,             'Sessions'),
    _NavDef(Icons.inventory_2_outlined, Icons.inventory_2,         'Snapshots'),
    _NavDef(Icons.link_outlined,        Icons.link,                'Share Links'),
    _NavDef(Icons.vpn_key_outlined,     Icons.vpn_key,             'API Keys'),
    _NavDef(Icons.delete_outlined,      Icons.delete,              'Recycle Bin'),
  ];
  static const _adminNavItem =
      _NavDef(Icons.admin_panel_settings_outlined, Icons.admin_panel_settings, 'Admin');
  static const _auditNavItem =
      _NavDef(Icons.history_outlined, Icons.history, 'Audit Log');
  static const _integrityNavItem =
      _NavDef(Icons.verified_user_outlined, Icons.verified_user, 'Integrity');
  static const _emailNavItem =
      _NavDef(Icons.email_outlined, Icons.email, 'Email Config');
  static const _duressNavItem =
      _NavDef(Icons.security_outlined, Icons.security, 'Duress Vault');

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Lock Vault'),
        content: const Text(
            'This will lock the vault and require your master password to re-open it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Lock')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ApiService().logout();
    if (mounted) context.read<AppState>().logout();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isAdmin = context.watch<AppState>().isAdmin;
    final navItems = [
      ..._coreNavItems,
      if (isAdmin) _auditNavItem,
      if (isAdmin) _integrityNavItem,
      if (isAdmin) _emailNavItem,
      if (isAdmin) _duressNavItem,
      if (isAdmin) _adminNavItem,
    ];
    // Pages are NOT const so each navigation creates a fresh widget tree.
    final pages = <Widget>[
      const DashboardScreen(),
      const TotpScreen(),
      const SafeScreen(),
      const NotesScreen(),
      const TagsScreen(),
      const GeneratorScreen(),
      const CsvImportScreen(),
      const SettingsScreen(),
      const BackupScreen(),
      const HealthScreen(),
      const SSHScreen(),
      const SessionsScreen(),
      const SnapshotScreen(),
      const ShareLinksScreen(),
      const ApiKeysScreen(),
      const RecycleBinScreen(),
      if (isAdmin) const AuditScreen(),
      if (isAdmin) const IntegrityScreen(),
      if (isAdmin) const EmailConfigScreen(),
      if (isAdmin) const DuressAdminScreen(),
      if (isAdmin) const AdminScreen(),
    ];
    final safeIndex = _selectedIndex.clamp(0, pages.length - 1);

    return Scaffold(
      backgroundColor: cs.surface,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Custom sidebar ──────────────────────────────────────────────
          // NOTE: We deliberately avoid NavigationRail here because its
          // `trailing` parameter receives unconstrained height from Flutter,
          // which causes silent layout failures on Windows in release builds.
          SizedBox(
            width: 220,
            child: Material(
              color: cs.surfaceContainer,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Logo
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
                    child: Row(
                      children: [
                        Icon(Icons.lock_outline_rounded,
                            color: cs.primary, size: 28),
                        const SizedBox(width: 12),
                        Text(
                          'AuthVault',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: cs.primary),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  const SizedBox(height: 8),

                  // Nav items — wrapped in scroll so they work on short windows
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < navItems.length; i++)
                            i == 7  // Settings (index 7) gets the sync badge
                                ? ListenableBuilder(
                                    listenable: SyncService.instance,
                                    builder: (ctx, _) {
                                      final pending = SyncService.instance.pendingCount;
                                      return Stack(
                                        alignment: Alignment.centerRight,
                                        clipBehavior: Clip.none,
                                        children: [
                                          _NavTile(
                                            def: navItems[i],
                                            selected: safeIndex == i,
                                            onTap: () =>
                                                setState(() => _selectedIndex = i),
                                          ),
                                          if (pending > 0)
                                            Positioned(
                                              right: 18,
                                              top: 8,
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(
                                                    horizontal: 5, vertical: 1),
                                                decoration: BoxDecoration(
                                                  color: Colors.orange,
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                ),
                                                child: Text(
                                                  '$pending',
                                                  style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 10,
                                                      fontWeight: FontWeight.bold),
                                                ),
                                              ),
                                            ),
                                        ],
                                      );
                                    },
                                  )
                              : _NavTile(
                                  def: navItems[i],
                                  selected: safeIndex == i,
                                  onTap: () => setState(() => _selectedIndex = i),
                                ),
                        ],
                      ),
                    ),
                  ),

                  // Lock button — always visible at the bottom of the sidebar
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.lock_outline,
                          color: cs.onSurfaceVariant),
                      title: Text('Lock',
                          style: TextStyle(color: cs.onSurfaceVariant)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      onTap: _logout,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const VerticalDivider(width: 1, thickness: 1),

          // ── Content area ────────────────────────────────────────────────
          // Wrapped in Material so the page always has a background colour
          // (prevents transparent/black rendering when the page widget itself
          // doesn't own a Scaffold).
          Expanded(
            child: Material(
              color: cs.surface,
              child: pages[safeIndex],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Shared nav-item helpers ─────────────────────────────────────────────────

class _NavDef {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const _NavDef(this.icon, this.selectedIcon, this.label);
}

class _NavTile extends StatelessWidget {
  final _NavDef def;
  final bool selected;
  final VoidCallback onTap;
  const _NavTile(
      {required this.def, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: ListTile(
        dense: true,
        leading: Icon(
          selected ? def.selectedIcon : def.icon,
          color: selected ? cs.primary : cs.onSurfaceVariant,
        ),
        title: Text(
          def.label,
          style: TextStyle(
            color: selected ? cs.primary : cs.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        selected: selected,
        selectedTileColor: cs.primaryContainer.withAlpha(100),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
        onTap: onTap,
      ),
    );
  }
}
