import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/safe_node.dart';
import '../../services/api_service.dart';
import 'record_view.dart';

class SafeScreen extends StatefulWidget {
  const SafeScreen({super.key});
  @override
  State<SafeScreen> createState() => _SafeScreenState();
}

class _SafeScreenState extends State<SafeScreen> {
  List<SafeFolder> _tree = [];
  bool _loading = true;
  String? _error;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    // Auto-refresh every 10 seconds without showing the loading spinner.
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
      final tree = await context.read<ApiService>().getSafe();
      setState(() { _tree = tree; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _silentRefresh() async {
    if (!mounted) return;
    try {
      final tree = await context.read<ApiService>().getSafe();
      if (mounted) setState(() => _tree = tree);
    } catch (_) {
      // Silent — keep showing current data on failure
    }
  }

  Future<void> _addRootFolder() async {
    final name = await _inputDialog(context, 'New Folder', 'Folder name');
    if (name == null || name.isEmpty) return;
    await context.read<ApiService>().createFolder(name);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 56, color: cs.error),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center,
                  style: TextStyle(color: cs.error)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_tree.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.shield_outlined, size: 72, color: cs.primaryContainer),
              const SizedBox(height: 24),
              Text('Password Safe is empty',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                'Create a folder to start organising\nyour passwords and notes.',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: _addRootFolder,
                icon: const Icon(Icons.create_new_folder),
                label: const Text('Create Folder'),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 14)),
              ),
            ],
          ),
        ),
      );
    }
    return Stack(children: [
      ListView(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 80),
        children: _tree
            .map((f) => _FolderTile(folder: f, depth: 0, onRefresh: _load))
            .toList(),
      ),
      Positioned(
        bottom: 16,
        right: 16,
        child: FloatingActionButton(
          onPressed: _addRootFolder,
          tooltip: 'New Root Folder',
          child: const Icon(Icons.create_new_folder),
        ),
      ),
    ]);
  }
}

class _FolderTile extends StatefulWidget {
  final SafeFolder folder;
  final int depth;
  final VoidCallback onRefresh;

  const _FolderTile({required this.folder, required this.depth, required this.onRefresh});

  @override
  State<_FolderTile> createState() => _FolderTileState();
}

class _FolderTileState extends State<_FolderTile> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiService>();
    final indent = (widget.depth * 16.0) + 8;
    final f = widget.folder;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.only(left: indent, right: 8),
          leading: Icon(_expanded ? Icons.folder_open : Icons.folder,
              color: Theme.of(context).colorScheme.primary),
          title: Text(f.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.note_add_outlined, size: 20),
                tooltip: 'Add Record',
                onPressed: () async {
                  final ok = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => RecordViewScreen(folderId: f.id!, folderName: f.name),
                    ),
                  );
                  if (ok == true) widget.onRefresh();
                },
              ),
              IconButton(
                icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                tooltip: 'Add Sub-folder',
                onPressed: () async {
                  final name = await _inputDialog(context, 'New Sub-folder', 'Folder name');
                  if (name == null || name.isEmpty) return;
                  await api.createFolder(name, parentId: f.id);
                  widget.onRefresh();
                },
              ),
              PopupMenuButton<String>(
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
                onSelected: (v) async {
                  if (v == 'rename') {
                    final name = await _inputDialog(context, 'Rename Folder', 'New name', initial: f.name);
                    if (name == null || name.isEmpty) return;
                    await api.updateFolder(f.id!, name);
                    widget.onRefresh();
                  } else if (v == 'delete') {
                    final ok = await _confirmDialog(context, 'Delete "${f.name}"?',
                        'This will also delete all sub-folders and records inside.');
                    if (ok == true) {
                      await api.deleteFolder(f.id!);
                      widget.onRefresh();
                    }
                  }
                },
              ),
              IconButton(
                icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                onPressed: () => setState(() => _expanded = !_expanded),
              ),
            ],
          ),
        ),
        if (_expanded) ...[
          // Records in this folder
          ...f.records.map((r) => _RecordTile(
                record: r,
                depth: widget.depth + 1,
                onRefresh: widget.onRefresh,
              )),
          // Sub-folders
          ...f.children.map((c) => _FolderTile(
                folder: c,
                depth: widget.depth + 1,
                onRefresh: widget.onRefresh,
              )),
        ],
      ],
    );
  }
}

class _RecordTile extends StatelessWidget {
  final SafeRecord record;
  final int depth;
  final VoidCallback onRefresh;

  const _RecordTile({required this.record, required this.depth, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final indent = (depth * 16.0) + 8;
    final api = context.read<ApiService>();

    return ListTile(
      contentPadding: EdgeInsets.only(left: indent, right: 8),
      leading: const Icon(Icons.article_outlined),
      title: Text(record.name),
      subtitle: record.login.isNotEmpty ? Text(record.login, style: const TextStyle(fontSize: 12)) : null,
      onTap: () async {
        final ok = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => RecordViewScreen(
              folderId: record.folderId,
              folderName: '',
              existing: record,
            ),
          ),
        );
        if (ok == true) onRefresh();
      },
      trailing: PopupMenuButton<String>(
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
        onSelected: (v) async {
          if (v == 'delete') {
            final ok = await _confirmDialog(context, 'Delete "${record.name}"?', '');
            if (ok == true) {
              await api.deleteRecord(record.id!);
              onRefresh();
            }
          }
        },
      ),
    );
  }
}

Future<String?> _inputDialog(BuildContext context, String title, String hint, {String? initial}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        decoration: InputDecoration(hintText: hint),
        autofocus: true,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

Future<bool?> _confirmDialog(BuildContext context, String title, String content) =>
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: content.isNotEmpty ? Text(content) : null,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
