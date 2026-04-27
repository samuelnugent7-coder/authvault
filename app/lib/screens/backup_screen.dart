import 'package:flutter/material.dart';

import '../services/backup_service.dart';
import '../services/backup_scheduler.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});
  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> with WidgetsBindingObserver {
  bool _hasPermission = false;
  bool _running = false;
  bool _scheduled = false;

  // Progress
  int _done = 0;
  int _total = 0;
  int _bytesUploaded = 0;
  String _currentFile = '';
  BackupResult? _lastResult;

  DateTime? _lastRun;
  Map<String, dynamic>? _lastStats;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadState();
    }
  }

  Future<void> _loadState() async {
    final hasPerm = await BackupService.hasPermissions();
    final lastRun = await BackupService.getLastRun();
    final stats = await BackupService.getLastStats();
    if (!mounted) return;
    setState(() {
      _hasPermission = hasPerm;
      _lastRun = lastRun;
      _lastStats = stats;
    });
  }

  Future<void> _requestPermissions() async {
    final granted = await BackupService.requestPermissions();
    if (!mounted) return;
    setState(() => _hasPermission = granted);
    if (granted && !_scheduled) {
      await BackupScheduler.scheduleNightly();
      setState(() => _scheduled = true);
    }
    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Grant "All Files Access" in the screen that opened, then return to AuthVault.'),
          duration: Duration(seconds: 6),
        ),
      );
    }
  }

  Future<void> _enableSchedule() async {
    await BackupScheduler.scheduleNightly();
    setState(() => _scheduled = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Nightly backup scheduled (runs ~2 AM when on WiFi & charging)')),
    );
  }

  Future<void> _runNow() async {
    if (!_hasPermission) {
      await _requestPermissions();
      if (!_hasPermission) return;
    }

    setState(() {
      _running = true;
      _done = 0;
      _total = 0;
      _bytesUploaded = 0;
      _currentFile = '';
      _lastResult = null;
    });

    final result = await BackupService.runBackup(
      onProgress: (done, total, bytes, file) {
        if (!mounted) return;
        setState(() {
          _done = done;
          _total = total;
          _bytesUploaded = bytes;
          _currentFile = file;
        });
      },
    );

    if (!mounted) return;
    final lastRun = await BackupService.getLastRun();
    final stats = await BackupService.getLastStats();
    setState(() {
      _running = false;
      _lastResult = result;
      _lastRun = lastRun;
      _lastStats = stats;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(),
          const SizedBox(height: 16),
          if (!_hasPermission) _PermissionBanner(onGrant: _requestPermissions),
          if (_hasPermission && !_scheduled) _ScheduleBanner(onEnable: _enableSchedule),
          if (_hasPermission) ...[
            const SizedBox(height: 8),
            _LastRunCard(lastRun: _lastRun, stats: _lastStats),
            const SizedBox(height: 16),
            if (_running) _ProgressCard(done: _done, total: _total, bytes: _bytesUploaded, file: _currentFile),
            if (!_running && _lastResult != null) _ResultCard(result: _lastResult!),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _running ? null : _runNow,
                icon: _running
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.backup),
                label: Text(_running ? 'Backing up…' : 'Back Up Now'),
              ),
            ),
          ],
          const SizedBox(height: 24),
          _InfoCard(),
        ],
    );
  }
}

// ---- Sub-widgets ----

class _StatusCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.phone_android, size: 40, color: Color(0xFF1A73E8)),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Nightly Phone Backup',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('Backs up ALL files to the AuthVault server.\nOnly changed files are uploaded.',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionBanner extends StatelessWidget {
  final VoidCallback onGrant;
  const _PermissionBanner({required this.onGrant});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.orange.withOpacity(0.12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.warning_amber, color: Colors.orange),
              SizedBox(width: 8),
              Text('Storage Permission Required', style: TextStyle(fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 8),
            const Text(
              'AuthVault needs "All Files Access" to back up your phone.\n'
              'This permission is used exclusively for backing up to your own server.',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onGrant,
              icon: const Icon(Icons.security),
              label: const Text('Grant Permission'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScheduleBanner extends StatelessWidget {
  final VoidCallback onEnable;
  const _ScheduleBanner({required this.onEnable});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.blue.withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.schedule, color: Colors.blueAccent),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('Nightly automatic backup is not yet scheduled.'),
            ),
            TextButton(onPressed: onEnable, child: const Text('Enable')),
          ],
        ),
      ),
    );
  }
}

class _LastRunCard extends StatelessWidget {
  final DateTime? lastRun;
  final Map<String, dynamic>? stats;
  const _LastRunCard({this.lastRun, this.stats});

  @override
  Widget build(BuildContext context) {
    final runStr = lastRun != null
        ? '${lastRun!.toLocal()}'.substring(0, 16)
        : 'Never';
    final uploaded = stats?['uploaded'] ?? 0;
    final newFiles = stats?['new_files'] ?? 0;
    final changedFiles = stats?['changed_files'] ?? 0;
    final skipped = stats?['skipped'] ?? 0;
    final bytes = _human(stats?['total_bytes'] ?? 0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Last Backup', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            _row(Icons.schedule, 'Time', runStr),
            _row(Icons.upload, 'Uploaded', '$uploaded files'),
            if (newFiles > 0) _row(Icons.fiber_new, 'New', '$newFiles files'),
            if (changedFiles > 0) _row(Icons.edit, 'Changed', '$changedFiles files'),
            _row(Icons.check, 'Unchanged', '$skipped files'),
            _row(Icons.data_usage, 'Transferred', bytes),
          ],
        ),
      ),
    );
  }

  Widget _row(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Icon(icon, size: 16, color: Colors.grey),
            const SizedBox(width: 8),
            Text('$label: ', style: const TextStyle(color: Colors.grey, fontSize: 13)),
            Text(value, style: const TextStyle(fontSize: 13)),
          ],
        ),
      );

  static String _human(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class _ProgressCard extends StatelessWidget {
  final int done;
  final int total;
  final int bytes;
  final String file;
  const _ProgressCard({required this.done, required this.total, required this.bytes, required this.file});

  @override
  Widget build(BuildContext context) {
    final pct = total > 0 ? done / total : 0.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sync, size: 18),
                const SizedBox(width: 8),
                Text(total == 0
                    ? file
                    : '$done / $total files'),
                const Spacer(),
                Text('${(pct * 100).toStringAsFixed(0)}%'),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: total > 0 ? pct : null, minHeight: 6),
            if (file.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(file, style: const TextStyle(fontSize: 12, color: Colors.grey),
                  overflow: TextOverflow.ellipsis),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final BackupResult result;
  const _ResultCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final color = result.isError
        ? Colors.red
        : result.errors > 0
            ? Colors.orange
            : Colors.green;
    return Card(
      color: color.withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(result.isError ? Icons.error_outline : Icons.check_circle_outline, color: color),
                const SizedBox(width: 12),
                Expanded(child: Text(result.isError ? result.errorMessage! : 'Backup complete', style: TextStyle(color: color, fontWeight: FontWeight.bold))),
              ],
            ),
            if (!result.isError) ...[  
              const SizedBox(height: 8),
              if (result.newFiles > 0)
                _statRow(Icons.fiber_new, 'New files', result.newFiles, Colors.green),
              if (result.changedFiles > 0)
                _statRow(Icons.edit, 'Changed', result.changedFiles, Colors.blue),
              if (result.skipped > 0)
                _statRow(Icons.check, 'Unchanged', result.skipped, Colors.grey),
              if (result.errors > 0)
                _statRow(Icons.error_outline, 'Errors', result.errors, Colors.red),
              if (result.totalBytes > 0) ...[  
                const SizedBox(height: 4),
                Text('Uploaded: ${_fmtBytes(result.totalBytes)}',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              ],
              if (result.failedFiles.isNotEmpty) ...[  
                const SizedBox(height: 6),
                for (final f in result.failedFiles.take(5))
                  Text('  • $f', style: const TextStyle(fontSize: 11, color: Colors.redAccent)),
                if (result.failedFiles.length > 5)
                  Text('  … and ${result.failedFiles.length - 5} more', style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _statRow(IconData icon, String label, int val, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text('$label: ', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            Text('$val', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      );

  static String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1 << 20) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1 << 30) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  }
}

class _InfoCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How it works', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            const Text(
              '• Runs every night at ~2 AM when connected to WiFi and charging\n'
              '• Only files that are new or changed since last run are uploaded\n'
              '• Files are stored on your AuthVault server under backups/<device-id>/\n'
              '• Everything travels over your private Tailscale network\n'
              '• No files are ever sent to any third party',
              style: TextStyle(fontSize: 13, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}
