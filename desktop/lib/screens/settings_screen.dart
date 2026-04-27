import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/sync_service.dart';
import '../services/vault_manager.dart';
import '../main.dart';
import 'vault_manage_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {

  Future<void> _importTotp() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: 'Import TOTP entries (Accounts.json)',
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path!;
    final content = await File(path).readAsString();
    try {
      final res = await ApiService().importTotp(content);
      if (mounted) _showSnack('Imported: ${res['imported']} entries, skipped: ${res['skipped']}');
    } catch (e) {
      if (mounted) _showSnack('Import failed: $e', error: true);
    }
  }

  Future<void> _exportTotp() async {
    try {
      final json = await ApiService().exportTotp();
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export TOTP entries',
        fileName: 'Accounts.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (path == null) return;
      await File(path).writeAsString(json);
      if (mounted) _showSnack('Exported to $path');
    } catch (e) {
      if (mounted) _showSnack('Export failed: $e', error: true);
    }
  }

  Future<void> _importSafe() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xml'],
      dialogTitle: 'Import Safe (safe.xml)',
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path!;
    final content = await File(path).readAsString();

    final replace = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Import Safe'),
        content: const Text(
            'Replace all existing data, or merge (keep existing)?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Merge')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (replace == null) return;
    try {
      final res = await ApiService().importSafe(content, replace: replace);
      if (mounted) _showSnack('Imported ${res['folders']} folders, ${res['records']} records');
    } catch (e) {
      if (mounted) _showSnack('Import failed: $e', error: true);
    }
  }

  Future<void> _exportSafe() async {
    try {
      final xml = await ApiService().exportSafe();
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Safe',
        fileName: 'safe.xml',
        type: FileType.custom,
        allowedExtensions: ['xml'],
      );
      if (path == null) return;
      await File(path).writeAsString(xml);
      if (mounted) _showSnack('Exported to $path');
    } catch (e) {
      if (mounted) _showSnack('Export failed: $e', error: true);
    }
  }

  void _showSnack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red : null,
      behavior: SnackBarBehavior.floating,
      width: 400,
    ));
  }

  Future<void> _logout() async {
    await ApiService().logout();
    if (mounted) context.read<AppState>().logout();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          elevation: 2,
          color: cs.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text('Settings',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          ),
        ),
        Expanded(child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // ── Sync
          ListenableBuilder(
            listenable: SyncService.instance,
            builder: (context, _) {
              final sync = SyncService.instance;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SectionHeader('Sync'),
                  Card(
                    color: cs.surfaceContainerHigh,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: sync.online
                                    ? Colors.green.withOpacity(0.15)
                                    : Colors.red.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: sync.online ? Colors.green : Colors.red),
                              ),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(
                                  sync.online ? Icons.wifi : Icons.wifi_off,
                                  size: 14,
                                  color: sync.online ? Colors.green : Colors.red,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  sync.online ? 'Online' : 'Offline',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: sync.online ? Colors.green : Colors.red),
                                ),
                              ]),
                            ),
                            const SizedBox(width: 12),
                            if (sync.pendingCount > 0)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.orange.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.orange),
                                ),
                                child: Text(
                                  '${sync.pendingCount} pending',
                                  style: const TextStyle(fontSize: 12, color: Colors.orange),
                                ),
                              ),
                          ]),
                          if (sync.lastSync != null) ...[  
                            const SizedBox(height: 8),
                            Text(
                              'Last sync: ${sync.lastSync!.toLocal().toString().substring(0, 19)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                          if (sync.lastError != null) ...[  
                            const SizedBox(height: 8),
                            Text(
                              'Error: ${sync.lastError}',
                              style: const TextStyle(fontSize: 12, color: Colors.red),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: sync.syncing ? null : () => SyncService.instance.sync(),
                            icon: sync.syncing
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.sync, size: 18),
                            label: Text(sync.syncing ? 'Syncing…' : 'Sync Now'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              );
            },
          ),

          // ── Connection
          _SectionHeader('Connection'),
          Card(
            color: cs.surfaceContainerHigh,
            child: ListenableBuilder(
              listenable: VaultManager.instance,
              builder: (_, __) {
                final vault = VaultManager.instance.active;
                return ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(vault?.name ?? 'No vault configured'),
                  subtitle: Text(vault?.apiBase ?? 'Click to add a vault'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const VaultManageScreen())),
                );
              },
            ),
          ),
          const SizedBox(height: 24),

          // ── Import / Export
          _SectionHeader('Authenticator — Import / Export'),
          Card(
            color: cs.surfaceContainerHigh,
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('Import TOTP (Accounts.json)'),
                subtitle: const Text('Add entries from a JSON export'),
                trailing: FilledButton(onPressed: _importTotp, child: const Text('Import')),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Export TOTP'),
                subtitle: const Text('Save all entries as Accounts.json'),
                trailing: OutlinedButton(onPressed: _exportTotp, child: const Text('Export')),
              ),
            ]),
          ),
          const SizedBox(height: 16),

          _SectionHeader('Password Safe — Import / Export'),
          Card(
            color: cs.surfaceContainerHigh,
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('Import Safe (safe.xml)'),
                subtitle: const Text('Import folders and records from XML'),
                trailing: FilledButton(onPressed: _importSafe, child: const Text('Import')),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Export Safe'),
                subtitle: const Text('Save vault as safe.xml'),
                trailing: OutlinedButton(onPressed: _exportSafe, child: const Text('Export')),
              ),
            ]),
          ),
          const SizedBox(height: 24),

          // ── Session
          _SectionHeader('Session'),
          Card(
            color: cs.surfaceContainerHigh,
            child: ListTile(
              leading: const Icon(Icons.lock_outline, color: Colors.orange),
              title: const Text('Lock Vault'),
              subtitle: const Text('Sign out and clear session'),
              trailing: OutlinedButton(
                onPressed: _logout,
                style: OutlinedButton.styleFrom(foregroundColor: Colors.orange),
                child: const Text('Lock'),
              ),
            ),
          ),
        ],
      )),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary)),
      );
}
