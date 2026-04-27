import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/vault_config.dart';
import '../services/vault_manager.dart';

class VaultManageScreen extends StatelessWidget {
  const VaultManageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vaults')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openSheet(context, null),
        child: const Icon(Icons.add),
      ),
      body: ListenableBuilder(
        listenable: VaultManager.instance,
        builder: (_, __) {
          final vaults = VaultManager.instance.vaults;
          if (vaults.isEmpty) {
            return const Center(child: Text('No vaults yet — tap + to add one'));
          }
          return ListView.builder(
            itemCount: vaults.length,
            itemBuilder: (_, i) {
              final v = vaults[i];
              final isActive = v.id == VaultManager.instance.active?.id;
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: isActive
                      ? BorderSide(
                          color: Theme.of(context).colorScheme.primary,
                          width: 2)
                      : BorderSide.none,
                ),
                child: ListTile(
                  leading: Icon(
                    Icons.dns_outlined,
                    color: isActive
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  title: Text(v.name,
                      style: isActive
                          ? TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.bold)
                          : null),
                  subtitle: Text(v.apiBase),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isActive)
                        const Chip(label: Text('Active')),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _openSheet(context, v),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _openSheet(BuildContext context, VaultConfig? existing) {
    showDialog(
      context: context,
      builder: (_) => _VaultEditDialog(vault: existing),
    );
  }
}

class _VaultEditDialog extends StatefulWidget {
  const _VaultEditDialog({this.vault});
  final VaultConfig? vault;

  @override
  State<_VaultEditDialog> createState() => _VaultEditDialogState();
}

class _VaultEditDialogState extends State<_VaultEditDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _apiCtrl;
  late final TextEditingController _backupCtrl;
  late bool _separateBackup;
  late bool _allowSelfSigned;

  @override
  void initState() {
    super.initState();
    final v = widget.vault;
    _nameCtrl = TextEditingController(text: v?.name ?? '');
    _apiCtrl = TextEditingController(text: v?.apiBase ?? '');
    _backupCtrl =
        TextEditingController(text: v?.backupApiBase ?? '');
    _separateBackup = v?.backupApiBase != null && v!.backupApiBase!.isNotEmpty;
    _allowSelfSigned = v?.allowSelfSigned ?? false;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _apiCtrl.dispose();
    _backupCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty || _apiCtrl.text.trim().isEmpty) return;
    final vm = VaultManager.instance;
    if (widget.vault == null) {
      await vm.addVault(VaultConfig(
        id: const Uuid().v4(),
        name: _nameCtrl.text.trim(),
        apiBase: _apiCtrl.text.trim(),
        backupApiBase:
            _separateBackup && _backupCtrl.text.trim().isNotEmpty
                ? _backupCtrl.text.trim()
                : null,
        allowSelfSigned: _allowSelfSigned,
      ));
    } else {
      await vm.updateVault(widget.vault!.copyWith(
        name: _nameCtrl.text.trim(),
        apiBase: _apiCtrl.text.trim(),
        backupApiBase:
            _separateBackup && _backupCtrl.text.trim().isNotEmpty
                ? _backupCtrl.text.trim()
                : null,
        clearBackupApiBase: !_separateBackup ||
            _backupCtrl.text.trim().isEmpty,
        allowSelfSigned: _allowSelfSigned,
      ));
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete vault?'),
        content: Text(
            'Remove "${widget.vault!.name}"? This won\'t affect the server.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await VaultManager.instance.deleteVault(widget.vault!.id);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.vault != null;
    final canDelete =
        isEdit && VaultManager.instance.vaults.length > 1;
    return AlertDialog(
      title: Text(isEdit ? 'Edit Vault' : 'New Vault'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiCtrl,
                decoration: const InputDecoration(
                  labelText: 'API Base URL',
                  hintText: 'https://vault.example.com:8443',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.dns_outlined),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                value: _allowSelfSigned,
                onChanged: (v) => setState(() => _allowSelfSigned = v),
                title: const Text('Allow self-signed certificate'),
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                value: _separateBackup,
                onChanged: (v) => setState(() => _separateBackup = v),
                title: const Text('Separate backup URL'),
                subtitle: const Text('e.g. LAN address for backups'),
                contentPadding: EdgeInsets.zero,
              ),
              if (_separateBackup) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _backupCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Backup API URL',
                    hintText: 'http://192.168.1.x:8443',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.backup_outlined),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (canDelete)
          TextButton(
            onPressed: _delete,
            style:
                TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
