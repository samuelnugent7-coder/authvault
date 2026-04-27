import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/vault_config.dart';
import '../services/api_service.dart';
import '../services/cache_service.dart';
import '../services/sync_service.dart';
import '../services/vault_manager.dart';
import 'login_screen.dart';

// ── Vault list / switcher ─────────────────────────────────────────────────────

class VaultManageScreen extends StatelessWidget {
  const VaultManageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vaults')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEdit(context, null),
        icon: const Icon(Icons.add),
        label: const Text('Add vault'),
      ),
      body: ListenableBuilder(
        listenable: VaultManager.instance,
        builder: (_, __) {
          final vaults = VaultManager.instance.vaults;
          if (vaults.isEmpty) {
            return const Center(
              child: Text('No vaults configured.\nTap + to add one.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey)),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
            itemCount: vaults.length,
            itemBuilder: (_, idx) {
              final v = vaults[idx];
              final isActive = v.id == VaultManager.instance.active?.id;
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                shape: isActive
                    ? RoundedRectangleBorder(
                        side: BorderSide(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2),
                        borderRadius: BorderRadius.circular(12))
                    : null,
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isActive
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey.withOpacity(0.2),
                    child: Text(
                      v.name.isNotEmpty ? v.name[0].toUpperCase() : '?',
                      style: TextStyle(
                          color: isActive ? Colors.white : null,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  title: Text(v.name),
                  subtitle: Text(
                    v.apiBase +
                        (v.backupApiBase != null
                            ? '\nBackup: ${v.backupApiBase}'
                            : ''),
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 11),
                  ),
                  isThreeLine: v.backupApiBase != null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isActive)
                        const Chip(
                          label: Text('Active'),
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                        ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _openEdit(context, v),
                      ),
                    ],
                  ),
                  onTap: () => _switchVault(context, v),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _openEdit(BuildContext ctx, VaultConfig? existing) async {
    await showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _VaultEditSheet(existing: existing),
    );
  }

  Future<void> _switchVault(BuildContext ctx, VaultConfig v) async {
    if (v.id == VaultManager.instance.active?.id) return;
    await VaultManager.instance.setActive(v);

    // Log out from whatever was cached so the new vault starts fresh.
    await CacheService.instance.clearAll();
    await SyncService.instance.reset();

    if (!ctx.mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(content: Text('Switched to "${v.name}"')),
    );
    // Return to login — requires fresh auth for the new vault.
    Navigator.of(ctx).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }
}

// ── Edit / Create vault sheet ──────────────────────────────────────────────────

class _VaultEditSheet extends StatefulWidget {
  final VaultConfig? existing;
  const _VaultEditSheet({this.existing});

  @override
  State<_VaultEditSheet> createState() => _VaultEditSheetState();
}

class _VaultEditSheetState extends State<_VaultEditSheet> {
  final _nameCtrl = TextEditingController();
  final _apiCtrl = TextEditingController();
  final _backupCtrl = TextEditingController();
  bool _separateBackup = false;
  bool _allowSelfSigned = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final v = widget.existing;
    if (v != null) {
      _nameCtrl.text = v.name;
      _apiCtrl.text = v.apiBase;
      _separateBackup = v.backupApiBase != null;
      _backupCtrl.text = v.backupApiBase ?? '';
      _allowSelfSigned = v.allowSelfSigned;
    } else {
      _nameCtrl.text = 'My Vault';
      _apiCtrl.text = 'http://100.64.0.1:8443';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _apiCtrl.dispose();
    _backupCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    final api = _apiCtrl.text.trim().replaceAll(RegExp(r'/$'), '');
    if (name.isEmpty || api.isEmpty) {
      setState(() => _error = 'Name and API address are required');
      return;
    }
    setState(() { _saving = true; _error = null; });
    final backupBase = _separateBackup && _backupCtrl.text.trim().isNotEmpty
        ? _backupCtrl.text.trim().replaceAll(RegExp(r'/$'), '')
        : null;

    final v = widget.existing != null
        ? widget.existing!.copyWith(
            name: name,
            apiBase: api,
            backupApiBase: backupBase,
            clearBackupApiBase: !_separateBackup,
            allowSelfSigned: _allowSelfSigned,
          )
        : VaultConfig(
            name: name,
            apiBase: api,
            backupApiBase: backupBase,
            allowSelfSigned: _allowSelfSigned,
          );

    if (widget.existing != null) {
      await VaultManager.instance.updateVault(v);
    } else {
      await VaultManager.instance.addVault(v);
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete vault?'),
        content: Text(
            'This will remove "${widget.existing!.name}" and its saved token. '
            'Your server data will not be affected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true) return;
    await VaultManager.instance.deleteVault(widget.existing!);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(isEdit ? 'Edit Vault' : 'Add Vault',
                  style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              if (isEdit && VaultManager.instance.vaults.length > 1)
                TextButton.icon(
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  label: const Text('Delete',
                      style: TextStyle(color: Colors.red)),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Display name',
              hintText: 'e.g. Home Server',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiCtrl,
            decoration: const InputDecoration(
              labelText: 'API address',
              hintText: 'http://100.64.0.1:8443  or  https://vault.example.com',
              border: OutlineInputBorder(),
              helperText: 'Supports http:// and https://',
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Use separate backup address'),
            subtitle: const Text(
                'Lets you use LAN (192.168.x.x) for backups\nand e.g. Tailscale for auth/TOTP'),
            value: _separateBackup,
            onChanged: (v) => setState(() => _separateBackup = v),
          ),
          if (_separateBackup) ...[
            const SizedBox(height: 4),
            TextField(
              controller: _backupCtrl,
              decoration: const InputDecoration(
                labelText: 'Backup-only address',
                hintText: 'http://192.168.1.10:8443',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
          ],
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Allow self-signed TLS certificates'),
            subtitle:
                const Text('Required for https:// with a self-signed cert'),
            value: _allowSelfSigned,
            onChanged: (v) => setState(() => _allowSelfSigned = v),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_error!,
                  style: const TextStyle(color: Colors.red)),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(isEdit ? 'Save' : 'Add'),
          ),
        ],
      ),
    );
  }
}
