import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../services/sync_service.dart';
import '../services/vault_manager.dart';
import 'vault_manage_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _msg;

  Future<void> _exportTotp() async {
    final api = context.read<ApiService>();
    try {
      final json = await api.exportTotp();
      setState(() => _msg = 'TOTP export ready (${json.length} bytes)');
      // On desktop save to file, on mobile share
      if (Platform.isWindows) {
        final path = '${Directory.current.path}\\Accounts_export.json';
        await File(path).writeAsString(json);
        setState(() => _msg = 'Saved to $path');
      }
    } catch (e) {
      setState(() => _msg = 'Error: $e');
    }
  }

  Future<void> _exportSafe() async {
    final api = context.read<ApiService>();
    try {
      final xml = await api.exportSafe();
      setState(() => _msg = 'Safe export ready (${xml.length} bytes)');
      if (Platform.isWindows) {
        final path = '${Directory.current.path}\\safe_export.xml';
        await File(path).writeAsString(xml);
        setState(() => _msg = 'Saved to $path');
      }
    } catch (e) {
      setState(() => _msg = 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Sync
        ListenableBuilder(
          listenable: SyncService.instance,
          builder: (context, _) {
            final sync = SyncService.instance;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Sync', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Row(children: [
                  Chip(
                    avatar: Icon(
                      sync.online ? Icons.wifi : Icons.wifi_off,
                      size: 14,
                      color: sync.online ? Colors.green : Colors.red,
                    ),
                    label: Text(sync.online ? 'Online' : 'Offline'),
                    backgroundColor: sync.online
                        ? Colors.green.withOpacity(0.12)
                        : Colors.red.withOpacity(0.12),
                  ),
                  if (sync.pendingCount > 0) ...[  
                    const SizedBox(width: 8),
                    Chip(
                      label: Text('${sync.pendingCount} pending'),
                      backgroundColor: Colors.orange.withOpacity(0.12),
                    ),
                  ],
                ]),
                if (sync.lastSync != null)
                  Text(
                    'Last sync: ${sync.lastSync!.toLocal().toString().substring(0, 19)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (sync.lastError != null)
                  Text('Error: ${sync.lastError}',
                      style: const TextStyle(color: Colors.red, fontSize: 12)),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: sync.syncing ? null : () => SyncService.instance.sync(),
                  icon: sync.syncing
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.sync, size: 18),
                  label: Text(sync.syncing ? 'Syncing…' : 'Sync Now'),
                ),
                const Divider(height: 40),
              ],
            );
          },
        ),
        Text('Connection', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        ListenableBuilder(
          listenable: VaultManager.instance,
          builder: (_, __) {
            final vault = VaultManager.instance.active;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: Text(vault?.name ?? 'No vault configured'),
              subtitle: Text(vault?.apiBase ?? 'Tap to add a vault'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const VaultManageScreen())),
            );
          },
        ),
        const Divider(height: 40),
        Text('Import / Export', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        _ImportTile(
          title: 'Import TOTP (Accounts.json)',
          icon: Icons.upload_file,
          onResult: (msg) => setState(() => _msg = msg),
          isTotp: true,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _exportTotp,
          icon: const Icon(Icons.download),
          label: const Text('Export TOTP (Accounts.json)'),
        ),
        const SizedBox(height: 16),
        _ImportTile(
          title: 'Import Safe (safe.xml)',
          icon: Icons.upload_file,
          onResult: (msg) => setState(() => _msg = msg),
          isTotp: false,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _exportSafe,
          icon: const Icon(Icons.download),
          label: const Text('Export Safe (safe.xml)'),
        ),
        if (_msg != null) ...[
          const SizedBox(height: 16),
          Text(_msg!, style: const TextStyle(color: Colors.greenAccent)),
        ],
      ],
    );
  }
}

class _ImportTile extends StatelessWidget {
  final String title;
  final IconData icon;
  final ValueChanged<String> onResult;
  final bool isTotp;

  const _ImportTile({
    required this.title,
    required this.icon,
    required this.onResult,
    required this.isTotp,
  });

  Future<void> _pick(BuildContext context) async {
    // On Windows, use a simple path input dialog
    String? path;
    if (Platform.isWindows) {
      final ctrl = TextEditingController();
      path = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Enter file path'),
          content: TextField(
            controller: ctrl,
            decoration: InputDecoration(hintText: isTotp ? r'C:\path\Accounts.json' : r'C:\path\safe.xml'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Import'),
            ),
          ],
        ),
      );
    }

    if (path == null || path.isEmpty) return;
    try {
      final content = await File(path).readAsString();
      final api = context.read<ApiService>();
      if (isTotp) {
        final res = await api.importTotp(content);
        onResult('Imported ${res['imported']} TOTP entries');
      } else {
        final replace = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Replace or merge?'),
                content: const Text('Replace will delete ALL existing safe data before importing.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Merge')),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Replace'),
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  ),
                ],
              ),
            ) ??
            false;
        final res = await api.importSafe(content, replace: replace);
        onResult('Imported ${res['imported_records']} records');
      }
    } catch (e) {
      onResult('Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: () => _pick(context),
        icon: Icon(icon),
        label: Text(title),
      );
}
