import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/safe_node.dart';
import '../../services/api_service.dart';
import 'record_view.dart';

class SafeScreen extends StatefulWidget {
  const SafeScreen({super.key});

  @override
  State<SafeScreen> createState() => _SafeScreenState();
}

class _SafeScreenState extends State<SafeScreen> {
  final _api = ApiService();
  List<SafeFolder> _folders = [];
  bool _loading = true;
  String? _error;
  SafeFolder? _selectedFolder;
  SafeRecord? _selectedRecord;
  String _search = '';
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) => _silentRefresh());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final tree = await _api.getSafe();
      // Flatten the tree so nested sub-folders also appear in the sidebar.
      final allFolders = tree.expand((f) => f.allFolders).toList();
      setState(() {
        _folders = allFolders;
        _loading = false;
        if (_selectedFolder != null) {
          _selectedFolder = allFolders.firstWhere(
            (f) => f.id == _selectedFolder!.id,
            orElse: () => allFolders.isNotEmpty ? allFolders.first : SafeFolder(name: ''),
          );
        }
      });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _silentRefresh() async {
    if (!mounted) return;
    try {
      final tree = await _api.getSafe();
      final allFolders = tree.expand((f) => f.allFolders).toList();
      if (!mounted) return;
      setState(() {
        _folders = allFolders;
        if (_selectedFolder != null) {
          _selectedFolder = allFolders.firstWhere(
            (f) => f.id == _selectedFolder!.id,
            orElse: () => _selectedFolder!,
          );
        }
      });
    } catch (_) {}
  }

  List<SafeRecord> get _filteredRecords {
    final folder = _selectedFolder;
    if (folder == null) return [];
    if (_search.isEmpty) return folder.records;
    final q = _search.toLowerCase();
    return folder.records.where((r) =>
        r.title.toLowerCase().contains(q) ||
        r.username.toLowerCase().contains(q) ||
        r.url.toLowerCase().contains(q)).toList();
  }

  Future<void> _addFolder() async {
    final name = await _inputDialog(context, 'New Folder', 'Folder name');
    if (name == null) return;
    try {
      final f = await _api.createFolder(name);
      setState(() { _folders.add(f); _selectedFolder = f; });
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  Future<void> _renameFolder(SafeFolder f) async {
    final name = await _inputDialog(context, 'Rename Folder', 'Folder name', initial: f.name);
    if (name == null) return;
    try {
      final updated = await _api.updateFolder(f.id!, name);
      setState(() {
        final i = _folders.indexWhere((x) => x.id == f.id);
        if (i >= 0) _folders[i] = updated;
        if (_selectedFolder?.id == f.id) _selectedFolder = updated;
      });
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  Future<void> _deleteFolder(SafeFolder f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${f.name}"?'),
        content: const Text('All records inside will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.deleteFolder(f.id!);
      setState(() {
        _folders.removeWhere((x) => x.id == f.id);
        if (_selectedFolder?.id == f.id) { _selectedFolder = null; _selectedRecord = null; }
      });
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  Future<void> _addRecord() async {
    if (_selectedFolder == null) return;
    final result = await showDialog<SafeRecord>(
      context: context,
      builder: (_) => RecordEditDialog(folderId: _selectedFolder!.id!),
    );
    if (result == null) return;
    try {
      final created = await _api.createRecord(result);
      await _load();
      setState(() => _selectedRecord = created);
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  Future<void> _editRecord(SafeRecord r) async {
    final result = await showDialog<SafeRecord>(
      context: context,
      builder: (_) => RecordEditDialog(record: r, folderId: r.folderId ?? _selectedFolder!.id!),
    );
    if (result == null) return;
    try {
      final updated = await _api.updateRecord(result);
      await _load();
      setState(() => _selectedRecord = updated);
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  Future<void> _deleteRecord(SafeRecord r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${r.title}"?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.deleteRecord(r.id!);
      await _load();
      setState(() => _selectedRecord = null);
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.error_outline, color: cs.error, size: 48),
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: cs.error)),
        const SizedBox(height: 16),
        FilledButton(onPressed: _load, child: const Text('Retry')),
      ]));
    }

    return Row(children: [
      // ── Folder list (left column)
      SizedBox(
        width: 200,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 4),
            child: Row(children: [
              Text('Folders',
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: cs.onSurfaceVariant)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                tooltip: 'New folder',
                onPressed: _addFolder,
              ),
            ]),
          ),
          Expanded(
            child: _folders.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.folder_open, size: 40, color: cs.primaryContainer),
                        const SizedBox(height: 12),
                        Text('No folders yet',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _addFolder,
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('New Folder'),
                          style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _folders.length,
              itemBuilder: (_, i) {
                final f = _folders[i];
                final selected = _selectedFolder?.id == f.id;
                return ListTile(
                  dense: true,
                  selected: selected,
                  selectedTileColor: cs.primaryContainer.withOpacity(0.4),
                  leading: Icon(Icons.folder_outlined, size: 20,
                      color: selected ? cs.primary : null),
                  title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert, size: 16, color: cs.onSurfaceVariant),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'rename', child: Text('Rename')),
                      const PopupMenuItem(value: 'delete',
                          child: Text('Delete', style: TextStyle(color: Colors.red))),
                    ],
                    onSelected: (v) {
                      if (v == 'rename') _renameFolder(f);
                      if (v == 'delete') _deleteFolder(f);
                    },
                  ),
                  onTap: () => setState(() { _selectedFolder = f; _selectedRecord = null; }),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  );
              },
            ),
          ),
        ]),
      ),
      const VerticalDivider(width: 1),
      // ── Record list (middle column)
      SizedBox(
        width: 240,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 4),
            child: Row(children: [
              Expanded(child: Text(
                  _selectedFolder?.name ?? 'Select a folder',
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: cs.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis)),
              if (_selectedFolder != null)
                IconButton(
                  icon: const Icon(Icons.add, size: 20),
                  tooltip: 'New record',
                  onPressed: _addRecord,
                ),
            ]),
          ),
          if (_selectedFolder != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'Search...',
                  prefixIcon: const Icon(Icons.search, size: 16),
                  filled: true,
                  fillColor: cs.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 6),
                ),
                onChanged: (v) => setState(() => _search = v),
              ),
            ),
          Expanded(
            child: _selectedFolder == null
                ? Center(child: Text('Select a folder',
                    style: TextStyle(color: cs.onSurfaceVariant)))
                : _filteredRecords.isEmpty
                    ? Center(child: Text(
                        _search.isEmpty ? 'No records' : 'No matches',
                        style: TextStyle(color: cs.onSurfaceVariant)))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        itemCount: _filteredRecords.length,
                        itemBuilder: (_, i) {
                          final r = _filteredRecords[i];
                          final selected = _selectedRecord?.id == r.id;
                          return ListTile(
                            dense: true,
                            selected: selected,
                            selectedTileColor: cs.primaryContainer.withOpacity(0.4),
                            leading: CircleAvatar(
                              radius: 14,
                              backgroundColor: cs.primaryContainer,
                              child: Text(
                                (r.title.isEmpty ? '?' : r.title[0]).toUpperCase(),
                                style: TextStyle(fontSize: 12, color: cs.onPrimaryContainer),
                              ),
                            ),
                            title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: r.username.isNotEmpty
                                ? Text(r.username, maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11))
                                : null,
                            onTap: () => setState(() => _selectedRecord = r),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          );
                        },
                      ),
          ),
        ]),
      ),
      const VerticalDivider(width: 1),
      // ── Record detail (right pane)
      Expanded(
        child: _selectedRecord == null
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.shield_outlined, size: 64, color: cs.primaryContainer),
                const SizedBox(height: 12),
                Text('Select a record to view details',
                    style: TextStyle(color: cs.onSurfaceVariant)),
              ]))
            : RecordView(
                record: _selectedRecord!,
                onEdit: () => _editRecord(_selectedRecord!),
                onDelete: () => _deleteRecord(_selectedRecord!),
              ),
      ),
    ]);
  }
}

// ─────────────────────────────────────────────
// Input Dialog Helper
// ─────────────────────────────────────────────
Future<String?> _inputDialog(
    BuildContext context, String title, String hint, {String initial = ''}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        decoration: InputDecoration(hintText: hint, border: const OutlineInputBorder()),
        autofocus: true,
        onSubmitted: (v) => Navigator.pop(_, v.trim().isEmpty ? null : v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(_), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final v = ctrl.text.trim();
            Navigator.pop(_, v.isEmpty ? null : v);
          },
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

// ─────────────────────────────────────────────
// Record Edit Dialog
// ─────────────────────────────────────────────
class RecordEditDialog extends StatefulWidget {
  final SafeRecord? record;
  final int folderId;
  const RecordEditDialog({super.key, this.record, required this.folderId});

  @override
  State<RecordEditDialog> createState() => _RecordEditDialogState();
}

class _RecordEditDialogState extends State<RecordEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title, _username, _password, _url, _notes;
  late List<SafeItem> _items;
  bool _showPass = false;

  @override
  void initState() {
    super.initState();
    final r = widget.record;
    _title = TextEditingController(text: r?.title ?? '');
    _username = TextEditingController(text: r?.username ?? '');
    _password = TextEditingController(text: r?.password ?? '');
    _url = TextEditingController(text: r?.url ?? '');
    _notes = TextEditingController(text: r?.notes ?? '');
    _items = List.from(r?.items ?? []);
  }

  @override
  void dispose() {
    _title.dispose(); _username.dispose();
    _password.dispose(); _url.dispose(); _notes.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, SafeRecord(
      id: widget.record?.id,
      folderId: widget.folderId,
      title: _title.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      url: _url.text.trim(),
      notes: _notes.text.trim(),
      items: _items,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.record != null;
    return AlertDialog(
      title: Text(isEdit ? 'Edit Record' : 'New Record'),
      content: SizedBox(
        width: 500,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Title *', border: OutlineInputBorder()),
              validator: (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(labelText: 'Username', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password,
              obscureText: !_showPass,
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showPass = !_showPass),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _url,
              decoration: const InputDecoration(labelText: 'URL', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notes,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Notes', border: OutlineInputBorder()),
            ),
            if (_items.isNotEmpty) ...[
              const SizedBox(height: 16),
              ...List.generate(_items.length, (i) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Expanded(flex: 2, child: TextFormField(
                    initialValue: _items[i].label,
                    decoration: const InputDecoration(labelText: 'Label', border: OutlineInputBorder(), isDense: true),
                    onChanged: (v) => _items[i] = SafeItem(id: _items[i].id, label: v, value: _items[i].value),
                  )),
                  const SizedBox(width: 8),
                  Expanded(flex: 3, child: TextFormField(
                    initialValue: _items[i].value,
                    decoration: const InputDecoration(labelText: 'Value', border: OutlineInputBorder(), isDense: true),
                    onChanged: (v) => _items[i] = SafeItem(id: _items[i].id, label: _items[i].label, value: v),
                  )),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline, size: 18),
                    onPressed: () => setState(() => _items.removeAt(i)),
                  ),
                ]),
              )),
            ],
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => setState(() => _items.add(const SafeItem(label: '', value: ''))),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add custom field'),
            ),
          ])),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: Text(isEdit ? 'Save' : 'Create')),
      ],
    );
  }
}
