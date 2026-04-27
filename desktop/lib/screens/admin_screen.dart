import 'package:flutter/material.dart';
import '../models/safe_node.dart';
import '../models/totp_entry.dart';
import '../models/user_info.dart';
import '../services/api_service.dart';
import '../services/vault_manager.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  final _api = ApiService();
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final users = await _api.adminListUsers();
      setState(() { _users = users; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _showAddUserDialog() async {
    final unameCtrl = TextEditingController();
    final pwCtrl = TextEditingController();
    bool isAdmin = false;
    String? err;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        title: const Text('Add User'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: unameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Username', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pwCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Password', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text('Admin user'),
              value: isAdmin,
              onChanged: (v) => setS(() => isAdmin = v),
              contentPadding: EdgeInsets.zero,
            ),
            if (err != null) ...[
              const SizedBox(height: 8),
              Text(err!, style: const TextStyle(color: Colors.redAccent)),
            ],
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final uname = unameCtrl.text.trim().toLowerCase();
              final pw = pwCtrl.text;
              if (uname.isEmpty || pw.isEmpty) {
                setS(() => err = 'Username and password required');
                return;
              }
              try {
                await _api.adminCreateUser(uname, pw, isAdmin: isAdmin);
                if (ctx.mounted) Navigator.pop(ctx);
                _load();
              } catch (e) {
                setS(() => err = e.toString());
              }
            },
            child: const Text('Create'),
          ),
        ],
      )),
    );
  }

  Future<void> _showEditDialog(Map<String, dynamic> user) async {
    final pwCtrl = TextEditingController();
    bool isAdmin = user['is_admin'] as bool? ?? false;
    final currentUsername = VaultManager.instance.username;
    final uid = user['id'] as int;
    String? err;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        title: Text('Edit ${user['username']}'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: pwCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New Password (leave blank to keep)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text('Admin user'),
              value: isAdmin,
              onChanged: user['username'] == currentUsername
                  ? null // can't remove own admin
                  : (v) => setS(() => isAdmin = v),
              contentPadding: EdgeInsets.zero,
            ),
            if (err != null) ...[
              const SizedBox(height: 8),
              Text(err!, style: const TextStyle(color: Colors.redAccent)),
            ],
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              try {
                await _api.adminUpdateUser(uid,
                    password: pwCtrl.text.isEmpty ? null : pwCtrl.text,
                    isAdmin: isAdmin);
                if (ctx.mounted) Navigator.pop(ctx);
                _load();
              } catch (e) {
                setS(() => err = e.toString());
              }
            },
            child: const Text('Save'),
          ),
        ],
      )),
    );
  }

  Future<void> _showPermissionsDialog(Map<String, dynamic> user) async {
    final uid = user['id'] as int;
    UserPermissions? perms;
    List<SafeFolder> folders = [];
    List<TotpEntry> totpEntries = [];
    String? err;
    bool loading = true;
    bool _loadStarted = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        if (!_loadStarted) {
          _loadStarted = true;
          Future.wait([
            _api.adminGetPermissions(uid),
            _api.getSafe(),
            _api.getTotpEntries(),
          ]).then((results) {
            setS(() {
              perms = UserPermissions.fromJson(results[0] as Map<String, dynamic>);
              folders = results[1] as List<SafeFolder>;
              totpEntries = results[2] as List<TotpEntry>;
              loading = false;
            });
          }).catchError((e) {
            setS(() { err = e.toString(); loading = false; });
          });
        }

        return DefaultTabController(
          length: 3,
          child: AlertDialog(
            title: Text('Permissions: ${user['username']}'),
            content: SizedBox(
              width: 580,
              height: 480,
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : err != null
                      ? Center(child: Text(err!, style: const TextStyle(color: Colors.redAccent)))
                      : Column(children: [
                          const TabBar(tabs: [
                            Tab(text: 'Sections'),
                            Tab(text: 'Safe Folders'),
                            Tab(text: 'TOTP Entries'),
                          ]),
                          Expanded(
                            child: TabBarView(children: [
                              // ─── Tab 1: Section-level perms ────────────────
                              SingleChildScrollView(
                                padding: const EdgeInsets.only(top: 12),
                                child: _SectionPermsEditor(
                                  perms: perms!,
                                  onChanged: (p) => setS(() => perms = p),
                                ),
                              ),
                              // ─── Tab 2: Per-folder overrides ───────────────
                              SingleChildScrollView(
                                padding: const EdgeInsets.only(top: 8),
                                child: _FolderPermsEditor(
                                  folders: folders,
                                  perms: perms!,
                                  onChanged: (p) => setS(() => perms = p),
                                ),
                              ),
                              // ─── Tab 3: Per-TOTP overrides ─────────────────
                              SingleChildScrollView(
                                padding: const EdgeInsets.only(top: 8),
                                child: _TotpPermsEditor(
                                  totpEntries: totpEntries,
                                  perms: perms!,
                                  onChanged: (p) => setS(() => perms = p),
                                ),
                              ),
                            ]),
                          ),
                        ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: loading || perms == null
                    ? null
                    : () async {
                        try {
                          await _api.adminSetPermissions(uid, perms!);
                          if (ctx.mounted) Navigator.pop(ctx);
                        } catch (e) {
                          setS(() => err = e.toString());
                        }
                      },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      }),
    );
  }

  Future<void> _deleteUser(Map<String, dynamic> user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete User'),
        content: Text('Delete "${user['username']}"? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.adminDeleteUser(user['id'] as int);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text('User Management'),
        backgroundColor: cs.surfaceContainer,
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Refresh'),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddUserDialog,
        icon: const Icon(Icons.person_add),
        label: const Text('Add User'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!,
                          style: TextStyle(color: cs.error)),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _users.length,
                  itemBuilder: (_, i) {
                    final u = _users[i];
                    final isAdminUser = u['is_admin'] as bool? ?? false;
                    final isSelf =
                        u['username'] == VaultManager.instance.username;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isAdminUser
                              ? cs.primaryContainer
                              : cs.surfaceContainerHigh,
                          child: Icon(
                            isAdminUser
                                ? Icons.admin_panel_settings
                                : Icons.person,
                            color: isAdminUser ? cs.primary : cs.onSurfaceVariant,
                          ),
                        ),
                        title: Row(children: [
                          Text(u['username'] as String? ?? ''),
                          if (isAdminUser) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: cs.primaryContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('admin',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: cs.primary,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
                          if (isSelf) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: cs.tertiaryContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('you',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: cs.tertiary,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ]),
                        subtitle: Text('ID: ${u['id']}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!isAdminUser)
                              IconButton(
                                icon: const Icon(Icons.tune),
                                tooltip: 'Edit Permissions',
                                onPressed: () => _showPermissionsDialog(u),
                              ),
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              tooltip: 'Edit User',
                              onPressed: () => _showEditDialog(u),
                            ),
                            if (!isSelf)
                              IconButton(
                                icon: Icon(Icons.delete_outline,
                                    color: cs.error),
                                tooltip: 'Delete User',
                                onPressed: () => _deleteUser(u),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

// ── Section-level permission editor ─────────────────────────────────────────

class _SectionPermsEditor extends StatelessWidget {
  final UserPermissions perms;
  final void Function(UserPermissions) onChanged;
  const _SectionPermsEditor({required this.perms, required this.onChanged});

  UserPermissions _patch(String resource, String action, bool value) {
    ResourcePerms patchRp(ResourcePerms r) => ResourcePerms(
          read: action == 'read' ? value : r.read,
          write: action == 'write' ? value : r.write,
          delete: action == 'delete' ? value : r.delete,
          export: action == 'export' ? value : r.export,
          import: action == 'import' ? value : r.import,
        );
    return perms.copyWith(
      totp: resource == 'totp' ? patchRp(perms.totp) : null,
      safe: resource == 'safe' ? patchRp(perms.safe) : null,
      backup: resource == 'backup' ? patchRp(perms.backup) : null,
      ssh: resource == 'ssh' ? patchRp(perms.ssh) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final sections = <String, ResourcePerms>{
      'totp': perms.totp,
      'safe': perms.safe,
      'backup': perms.backup,
      'ssh': perms.ssh,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: sections.entries.map((entry) {
        final res = entry.key;
        final rp = entry.value;
        final hasExportImport = res == 'totp' || res == 'safe';
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(res.toUpperCase(),
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          Wrap(children: [
            _CheckBox(label: 'Read', value: rp.read,
                onChanged: (v) => onChanged(_patch(res, 'read', v))),
            _CheckBox(label: 'Write', value: rp.write,
                onChanged: (v) => onChanged(_patch(res, 'write', v))),
            _CheckBox(label: 'Delete', value: rp.delete,
                onChanged: (v) => onChanged(_patch(res, 'delete', v))),
            if (hasExportImport) ...[
              _CheckBox(label: 'Export', value: rp.export,
                  onChanged: (v) => onChanged(_patch(res, 'export', v))),
              _CheckBox(label: 'Import', value: rp.import,
                  onChanged: (v) => onChanged(_patch(res, 'import', v))),
            ],
          ]),
        ]);
      }).toList(),
    );
  }
}

// ── Per-folder permission editor ─────────────────────────────────────────────

class _FolderPermsEditor extends StatelessWidget {
  final List<SafeFolder> folders;
  final UserPermissions perms;
  final void Function(UserPermissions) onChanged;
  const _FolderPermsEditor(
      {required this.folders, required this.perms, required this.onChanged});

  List<Widget> _buildRows(List<SafeFolder> list, int depth) {
    final rows = <Widget>[];
    for (final f in list) {
      if (f.id == null) continue;
      final id = f.id.toString();
      final fp = perms.folderPerms[id];
      // "blocked" = explicit deny
      final blockRead = fp != null && !fp.read;
      final blockWrite = fp != null && !fp.write;

      rows.add(Padding(
        padding: EdgeInsets.only(left: depth * 16.0),
        child: Row(children: [
          Icon(Icons.folder_outlined, size: 16,
              color:  Colors.amber.shade700),
          const SizedBox(width: 6),
          Expanded(child: Text(f.name, overflow: TextOverflow.ellipsis)),
          _BlockToggle(
            label: 'Block Read',
            blocked: blockRead,
            onChanged: (v) {
              final updated = Map<String, ResourcePerms>.from(perms.folderPerms);
              if (v) {
                // Block: set read=false, preserve write
                updated[id] = ResourcePerms(
                    read: false, write: fp?.write ?? true, delete: fp?.delete ?? true);
              } else {
                // Unblock: set read=true (or remove key if write also true)
                final newFp = ResourcePerms(
                    read: true, write: fp?.write ?? true, delete: fp?.delete ?? true);
                if (newFp.read && newFp.write && newFp.delete) {
                  updated.remove(id);
                } else {
                  updated[id] = newFp;
                }
              }
              onChanged(perms.copyWith(folderPerms: updated));
            },
          ),
          const SizedBox(width: 8),
          _BlockToggle(
            label: 'Block Write',
            blocked: blockWrite,
            onChanged: (v) {
              final updated = Map<String, ResourcePerms>.from(perms.folderPerms);
              if (v) {
                updated[id] = ResourcePerms(
                    read: fp?.read ?? true, write: false, delete: fp?.delete ?? true);
              } else {
                final newFp = ResourcePerms(
                    read: fp?.read ?? true, write: true, delete: fp?.delete ?? true);
                if (newFp.read && newFp.write && newFp.delete) {
                  updated.remove(id);
                } else {
                  updated[id] = newFp;
                }
              }
              onChanged(perms.copyWith(folderPerms: updated));
            },
          ),
        ]),
      ));
      if (f.children.isNotEmpty) {
        rows.addAll(_buildRows(f.children, depth + 1));
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    if (folders.isEmpty) {
      return const Center(child: Text('No folders found.'));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Block read/write on specific folders. Inherits section permission by default.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ),
        ..._buildRows(folders, 0),
      ],
    );
  }
}

// ── Per-TOTP permission editor ────────────────────────────────────────────────

class _TotpPermsEditor extends StatelessWidget {
  final List<TotpEntry> totpEntries;
  final UserPermissions perms;
  final void Function(UserPermissions) onChanged;
  const _TotpPermsEditor(
      {required this.totpEntries, required this.perms, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    if (totpEntries.isEmpty) {
      return const Center(child: Text('No TOTP entries found.'));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Block read/write on individual TOTP entries. Inherits section permission by default.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ),
        ...totpEntries.map((e) {
          if (e.id == null) return const SizedBox.shrink();
          final id = e.id.toString();
          final tp = perms.totpPerms[id];
          final blockRead = tp != null && !tp.read;
          final blockWrite = tp != null && !tp.write;
          return Row(children: [
            const Icon(Icons.lock_clock, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                e.issuer.isEmpty ? e.name : '${e.issuer}: ${e.name}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _BlockToggle(
              label: 'Block Read',
              blocked: blockRead,
              onChanged: (v) {
                final updated = Map<String, ResourcePerms>.from(perms.totpPerms);
                if (v) {
                  updated[id] = ResourcePerms(
                      read: false, write: tp?.write ?? true, delete: tp?.delete ?? true);
                } else {
                  final n = ResourcePerms(
                      read: true, write: tp?.write ?? true, delete: tp?.delete ?? true);
                  if (n.read && n.write && n.delete) updated.remove(id); else updated[id] = n;
                }
                onChanged(perms.copyWith(totpPerms: updated));
              },
            ),
            const SizedBox(width: 8),
            _BlockToggle(
              label: 'Block Write',
              blocked: blockWrite,
              onChanged: (v) {
                final updated = Map<String, ResourcePerms>.from(perms.totpPerms);
                if (v) {
                  updated[id] = ResourcePerms(
                      read: tp?.read ?? true, write: false, delete: tp?.delete ?? true);
                } else {
                  final n = ResourcePerms(
                      read: tp?.read ?? true, write: true, delete: tp?.delete ?? true);
                  if (n.read && n.write && n.delete) updated.remove(id); else updated[id] = n;
                }
                onChanged(perms.copyWith(totpPerms: updated));
              },
            ),
          ]);
        }),
      ],
    );
  }
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _CheckBox extends StatelessWidget {
  final String label;
  final bool value;
  final void Function(bool) onChanged;
  const _CheckBox({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
      Text(label),
      const SizedBox(width: 8),
    ]);
  }
}

class _BlockToggle extends StatelessWidget {
  final String label;
  final bool blocked;
  final void Function(bool) onChanged;
  const _BlockToggle({required this.label, required this.blocked, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => onChanged(!blocked),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: blocked
              ? Theme.of(context).colorScheme.errorContainer
              : Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(
            blocked ? Icons.block : Icons.check_circle_outline,
            size: 14,
            color: blocked
                ? Theme.of(context).colorScheme.onErrorContainer
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: blocked
                  ? Theme.of(context).colorScheme.onErrorContainer
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ]),
      ),
    );
  }
}
