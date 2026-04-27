import 'package:flutter/material.dart';
import '../services/api_service.dart';

class SnapshotScreen extends StatefulWidget {
  const SnapshotScreen({super.key});
  @override
  State<SnapshotScreen> createState() => _SnapshotScreenState();
}

class _SnapshotScreenState extends State<SnapshotScreen> {
  final _api = ApiService();
  List<Map<String, dynamic>> _snapshots = [];
  Map<String, dynamic>? _health;
  bool _loading = true;
  String? _error;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        _api.getSnapshots(),
        _api.getBackupHealth(),
      ]);
      final snapData = results[0];
      setState(() {
        _snapshots = (snapData['snapshots'] as List?)
            ?.cast<Map<String, dynamic>>() ?? [];
        _health = results[1];
        _loading = false;
      });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _create(String type) async {
    setState(() => _working = true);
    try {
      await _api.triggerSnapshot(type: type);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$type snapshot created'), backgroundColor: Colors.green));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    } finally {
      setState(() => _working = false);
    }
  }

  Future<void> _restore(Map<String, dynamic> snap) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore Snapshot'),
        content: Text(
          'Restore to snapshot #${snap['id']} (${snap['type']}) '
          'from ${_formatTime(snap['created_at'])}?\n\n'
          'WARNING: This will REPLACE all current vault data.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _working = true);
    try {
      await _api.restoreSnapshot(snap['id'] as int);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Vault restored successfully'), backgroundColor: Colors.green));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restore error: $e'), backgroundColor: Colors.red));
      }
    } finally {
      setState(() => _working = false);
    }
  }

  Future<void> _delete(Map<String, dynamic> snap) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Snapshot'),
        content: Text('Delete snapshot #${snap['id']}? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.deleteSnapshot(snap['id'] as int);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete error: $e'), backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Encrypted Snapshots'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHealthBanner(),
                    _buildActionBar(),
                    const Divider(height: 1),
                    Expanded(child: _buildSnapshotList()),
                  ],
                ),
    );
  }

  Widget _buildHealthBanner() {
    if (_health == null) return const SizedBox.shrink();
    final queueDepth = _health!['queue_depth'] as int? ?? 0;
    final lastSuccess = _health!['last_success_at'] as int? ?? 0;
    final s3Enabled = _health!['s3_enabled'] as bool? ?? false;
    final snapCount = _health!['snapshot_count'] as int? ?? 0;
    final snapBytes = _health!['total_size_bytes'] as int? ?? 0;

    Color bannerColor = Colors.grey.shade100;
    String statusText = '';
    Color statusColor = Colors.grey;

    if (queueDepth > 0) {
      bannerColor = Colors.orange.shade50;
      statusText = 'S3 retry queue: $queueDepth task(s) pending';
      statusColor = Colors.orange;
    } else if (s3Enabled && lastSuccess > 0) {
      bannerColor = Colors.green.shade50;
      statusText = 'Last S3 upload: ${_formatTime(lastSuccess)}';
      statusColor = Colors.green;
    } else if (!s3Enabled) {
      statusText = 'S3 backup disabled';
      statusColor = Colors.grey;
    }

    return Container(
      color: bannerColor,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.health_and_safety, color: statusColor, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(statusText, style: TextStyle(color: statusColor))),
          Text(
            '$snapCount snapshot${snapCount == 1 ? '' : 's'} · ${_formatBytes(snapBytes)}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildActionBar() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          ElevatedButton.icon(
            icon: const Icon(Icons.camera_alt),
            label: const Text('Full Snapshot'),
            onPressed: _working ? null : () => _create('full'),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.difference),
            label: const Text('Incremental'),
            onPressed: _working ? null : () => _create('incremental'),
          ),
          if (_working) ...[
            const SizedBox(width: 16),
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
          const Spacer(),
          Text(_snapshots.isEmpty ? 'No snapshots' : '${_snapshots.length} snapshots',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildSnapshotList() {
    if (_snapshots.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('No snapshots yet.\nCreate a Full Snapshot to get started.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return ListView.separated(
      itemCount: _snapshots.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final s = _snapshots[i];
        final type = s['type'] as String? ?? 'full';
        final isFull = type == 'full';
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: isFull ? Colors.blue.shade100 : Colors.teal.shade100,
            child: Icon(
              isFull ? Icons.camera_alt : Icons.difference,
              size: 18,
              color: isFull ? Colors.blue.shade700 : Colors.teal.shade700,
            ),
          ),
          title: Row(
            children: [
              Text('#${s['id']}  ', style: const TextStyle(fontWeight: FontWeight.bold)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: isFull ? Colors.blue.shade50 : Colors.teal.shade50,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(type,
                    style: TextStyle(
                        fontSize: 11,
                        color: isFull ? Colors.blue.shade700 : Colors.teal.shade700)),
              ),
              if (s['s3_uploaded'] == true) ...[
                const SizedBox(width: 8),
                const Icon(Icons.cloud_done, size: 14, color: Colors.green),
              ],
            ],
          ),
          subtitle: Text(
            '${_formatTime(s['created_at'])}  ·  '
            '${s['record_count'] ?? 0} records  ·  '
            '${_formatBytes(s['size_bytes'] as int? ?? 0)}'
            '${!isFull ? '  ·  base: #${s['base_id']}' : ''}',
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.restore, color: Colors.orange),
                tooltip: 'Restore to this point',
                onPressed: _working ? null : () => _restore(s),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                tooltip: 'Delete snapshot',
                onPressed: _working ? null : () => _delete(s),
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatTime(dynamic ts) {
    if (ts == null) return '';
    try {
      final dt = DateTime.fromMillisecondsSinceEpoch((ts as int) * 1000, isUtc: true).toLocal();
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return ts.toString();
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
}
