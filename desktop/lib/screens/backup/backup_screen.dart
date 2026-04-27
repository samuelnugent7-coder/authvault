import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../services/desktop_backup_service.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  late Future<DesktopBackupConfig> _configFuture;
  DesktopBackupConfig? _cfg;

  // Run state
  bool _running = false;
  bool _cancelled = false;
  int _done = 0;
  int _total = 0;
  int _bytes = 0;
  String _currentFile = '';
  DesktopBackupResult? _lastResult;
  Map<String, dynamic>? _persistedResult;

  // S3 retry queue stats
  Map<String, dynamic>? _s3Health;
  bool _clearingQueue = false;

  final _scheduleOptions = const [
    (0, 'Manual only'),
    (6, 'Every 6 hours'),
    (12, 'Every 12 hours'),
    (24, 'Daily'),
    (168, 'Weekly'),
  ];

  @override
  void initState() {
    super.initState();
    _configFuture = _load();
  }

  Future<DesktopBackupConfig> _load() async {
    final cfg = await DesktopBackupService.loadConfig();
    final last = await DesktopBackupService.loadLastResult();
    setState(() {
      _cfg = cfg;
      _persistedResult = last;
    });
    // Load S3 queue health in the background (non-critical)
    ApiService().getBackupHealth().then((h) {
      if (mounted) setState(() => _s3Health = h);
    }).catchError((_) {});
    return cfg;
  }

  Future<void> _save() async {
    if (_cfg == null) return;
    await DesktopBackupService.saveConfig(_cfg!);
  }

  Future<void> _addPath() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select a folder to back up',
      lockParentWindow: true,
    );
    if (result == null) return;
    if (_cfg!.includePaths.contains(result)) return;
    setState(() => _cfg!.includePaths.add(result));
    await _save();
  }

  Future<void> _removePath(int idx) async {
    setState(() => _cfg!.includePaths.removeAt(idx));
    await _save();
  }

  Future<void> _addExclude() async {
    final ctrl = TextEditingController();
    final val = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add exclusion pattern'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g. *.tmp  or  node_modules',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Add')),
        ],
      ),
    );
    if (val == null || val.isEmpty) return;
    if (_cfg!.excludePatterns.contains(val)) return;
    setState(() => _cfg!.excludePatterns.add(val));
    await _save();
  }

  Future<void> _removeExclude(int idx) async {
    setState(() => _cfg!.excludePatterns.removeAt(idx));
    await _save();
  }

  Future<void> _runBackup() async {
    if (_cfg == null || _running) return;
    setState(() {
      _running = true;
      _cancelled = false;
      _done = 0;
      _total = 0;
      _bytes = 0;
      _currentFile = 'Starting…';
      _lastResult = null;
    });

    final result = await DesktopBackupService.runBackup(
      cfg: _cfg!,
      onProgress: (done, total, bytes, file) {
        if (!mounted) return;
        setState(() {
          _done = done;
          _total = total;
          _bytes = bytes;
          _currentFile = file;
        });
      },
      isCancelled: () => _cancelled,
    );

    if (!mounted) return;
    setState(() {
      _running = false;
      _lastResult = result;
      _persistedResult = null;
    });
    // Reload to pick up persisted result
    await DesktopBackupService.loadLastResult().then((r) {
      if (mounted) setState(() => _persistedResult = r);
    });
  }

  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DesktopBackupConfig>(
      future: _configFuture,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(),
                const SizedBox(height: 20),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Column(
                        children: [
                          _sourcesCard(),
                          const SizedBox(height: 16),
                          _exclusionsCard(),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 2,
                      child: Column(
                        children: [
                          _scheduleCard(),
                          const SizedBox(height: 16),
                          _statusCard(),
                        ],
                      ),
                    ),
                  ],
                ),
                // S3 retry queue panel (shows only when there are queued tasks)
                if (_s3Health != null && ((_s3Health!['queue_depth'] as int? ?? 0) > 0)) ...[
                  const SizedBox(height: 16),
                  _s3QueueCard(),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header() {
    return Row(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Backup',
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Upload files to your AuthVault server',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: Colors.grey)),
          ],
        ),
        const Spacer(),
        if (_running)
          OutlinedButton.icon(
            onPressed: () => setState(() => _cancelled = true),
            icon: const Icon(Icons.stop),
            label: const Text('Cancel'),
          )
        else
          FilledButton.icon(
            onPressed: _cfg != null ? _runBackup : null,
            icon: const Icon(Icons.backup),
            label: const Text('Back Up Now'),
          ),
      ],
    );
  }

  // ── Sources ───────────────────────────────────────────────────────────────

  Widget _sourcesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.folder_open, size: 18),
                const SizedBox(width: 8),
                const Text('Source Folders',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  onPressed: _running ? null : _addPath,
                  icon: const Icon(Icons.add_circle_outline),
                  tooltip: 'Add folder',
                ),
              ],
            ),
            const Divider(height: 12),
            if (_cfg == null || _cfg!.includePaths.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(
                    child: Text('No folders added',
                        style: TextStyle(color: Colors.grey))),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _cfg!.includePaths.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, idx) {
                  final path = _cfg!.includePaths[idx];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.folder, size: 20),
                    title: Text(path,
                        style: const TextStyle(fontFamily: 'monospace')),
                    trailing: IconButton(
                      icon: const Icon(Icons.remove_circle_outline, size: 18),
                      onPressed:
                          _running ? null : () => _removePath(idx),
                      tooltip: 'Remove',
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  // ── Exclusions ─────────────────────────────────────────────────────────────

  Widget _exclusionsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.block, size: 18),
                const SizedBox(width: 8),
                const Text('Exclusions',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  onPressed: _running ? null : _addExclude,
                  icon: const Icon(Icons.add_circle_outline),
                  tooltip: 'Add exclusion pattern',
                ),
              ],
            ),
            const Divider(height: 12),
            if (_cfg == null || _cfg!.excludePatterns.isEmpty)
              const SizedBox(
                  height: 40,
                  child: Center(
                      child: Text('None',
                          style: TextStyle(color: Colors.grey))))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (int i = 0; i < _cfg!.excludePatterns.length; i++)
                    Chip(
                      label: Text(_cfg!.excludePatterns[i],
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12)),
                      onDeleted:
                          _running ? null : () => _removeExclude(i),
                      deleteIcon: const Icon(Icons.close, size: 14),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  // ── Schedule ───────────────────────────────────────────────────────────────

  Widget _scheduleCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.schedule, size: 18),
                const SizedBox(width: 8),
                const Text('Schedule',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Switch(
                  value: _cfg?.enabled ?? false,
                  onChanged: _running
                      ? null
                      : (v) {
                          setState(() => _cfg!.enabled = v);
                          _save();
                        },
                ),
              ],
            ),
            const Divider(height: 12),
            if (_cfg != null) ...[
              DropdownButtonFormField<int>(
                value: _cfg!.scheduleHours,
                decoration: const InputDecoration(
                  labelText: 'Frequency',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: _scheduleOptions
                    .map((opt) => DropdownMenuItem(
                          value: opt.$1,
                          child: Text(opt.$2),
                        ))
                    .toList(),
                onChanged: _running
                    ? null
                    : (v) {
                        if (v == null) return;
                        setState(() => _cfg!.scheduleHours = v);
                        _save();
                      },
              ),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: _cfg!.scheduleTime,
                enabled: !_running && _cfg!.scheduleHours > 0,
                decoration: const InputDecoration(
                  labelText: 'Start time (HH:MM)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  _cfg!.scheduleTime = v;
                  _save();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Status / Progress ─────────────────────────────────────────────────────

  Widget _statusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline, size: 18),
                const SizedBox(width: 8),
                const Text('Status',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const Divider(height: 12),
            if (_running) _progressWidget() else _resultWidget(),
          ],
        ),
      ),
    );
  }

  Widget _s3QueueCard() {
    final depth = (_s3Health!['queue_depth'] as int? ?? 0);
    final lastErr = (_s3Health!['last_error'] as String? ?? '');
    return Card(
      color: Theme.of(context).colorScheme.errorContainer.withAlpha(80),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('S3 Retry Queue: $depth task${depth == 1 ? '' : 's'} pending',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  if (lastErr.isNotEmpty)
                    Text(lastErr,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: Colors.orange)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _clearingQueue
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : OutlinedButton.icon(
                    onPressed: _clearS3Queue,
                    icon: const Icon(Icons.delete_sweep, size: 18),
                    label: const Text('Clear Queue'),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.orange),
                  ),
          ],
        ),
      ),
    );
  }

  Future<void> _clearS3Queue() async {
    setState(() => _clearingQueue = true);
    try {
      final res = await ApiService().clearBackupQueue();
      final n = res['cleared'] as int? ?? 0;
      if (mounted) {
        setState(() { _s3Health = null; _clearingQueue = false; });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cleared $n stale S3 retry tasks.')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _clearingQueue = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to clear queue: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _progressWidget() {
    final pct = _total > 0 ? _done / _total : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: pct),
        const SizedBox(height: 8),
        if (_total > 0)
          Text('$_done / $_total files',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
          _currentFile,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        if (_bytes > 0) ...[
          const SizedBox(height: 4),
          Text(_human(_bytes),
              style: const TextStyle(fontSize: 12)),
        ],
      ],
    );
  }

  Widget _resultWidget() {
    if (_lastResult != null) {
      return _resultTile(_lastResult!.newFiles, _lastResult!.changedFiles,
          _lastResult!.skipped, _lastResult!.errors, _lastResult!.totalBytes,
          _lastResult!.failedFiles);
    }
    final r = _persistedResult;
    if (r != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (r['ran_at'] != null)
            Text('Last run: ${_fmtTime(r['ran_at'])}',
                style:
                    const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 8),
          _resultTile(
            (r['new_files'] as int?) ?? 0,
            (r['changed_files'] as int?) ?? 0,
            (r['skipped'] as int?) ?? 0,
            (r['errors'] as int?) ?? 0,
            (r['total_bytes'] as int?) ?? 0,
            List<String>.from(r['failed'] as List? ?? []),
          ),
        ],
      );
    }
    return const Text('No backups run yet',
        style: TextStyle(color: Colors.grey));
  }

  Widget _resultTile(int newF, int changed, int skipped, int errors,
      int bytes, List<String> failed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _statRow('New', newF, Colors.green),
        _statRow('Changed', changed, Colors.blue),
        _statRow('Unchanged', skipped, Colors.grey),
        if (errors > 0) _statRow('Errors', errors, Colors.red),
        if (bytes > 0) ...[
          const SizedBox(height: 8),
          Text('Uploaded: ${_human(bytes)}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
        if (failed.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('Failed files:',
              style: TextStyle(fontSize: 12, color: Colors.red)),
          for (final f in failed.take(5))
            Text('  • $f',
                style:
                    const TextStyle(fontSize: 11, color: Colors.redAccent),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          if (failed.length > 5)
            Text('  … and ${failed.length - 5} more',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ],
    );
  }

  Widget _statRow(String label, int val, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
              width: 80,
              child: Text(label,
                  style: const TextStyle(fontSize: 13))),
          Text('$val',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: color)),
        ],
      ),
    );
  }

  static String _human(int b) {
    if (b < 1024) return '$b B';
    if (b < 1 << 20) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1 << 30) return '${(b >> 20)} MB';
    return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  }

  static String _fmtTime(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.day}/${dt.month}/${dt.year} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}
