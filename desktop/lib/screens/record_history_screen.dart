import 'package:flutter/material.dart';
import '../services/api_service.dart';

/// Shows password history and version history for a record.
class RecordHistoryScreen extends StatefulWidget {
  final int recordId;
  final String recordName;
  const RecordHistoryScreen({super.key, required this.recordId, required this.recordName});
  @override
  State<RecordHistoryScreen> createState() => _RecordHistoryScreenState();
}

class _RecordHistoryScreenState extends State<RecordHistoryScreen>
    with SingleTickerProviderStateMixin {
  final _api = ApiService();
  late final TabController _tab;
  List<Map<String, dynamic>> _history = [];
  List<Map<String, dynamic>> _versions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _api.getPasswordHistory(widget.recordId),
        _api.getRecordVersions(widget.recordId),
      ]);
      _history = results[0];
      _versions = results[1];
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _restoreVersion(int versionId) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Restore Version?'),
      content: const Text('This will overwrite the current record with this version.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Restore')),
      ],
    ));
    if (ok != true) return;
    try {
      await _api.restoreRecordVersion(versionId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Version restored')));
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('History: ${widget.recordName}'),
        bottom: TabBar(controller: _tab, tabs: const [
          Tab(text: 'Password History'),
          Tab(text: 'Versions'),
        ]),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(controller: _tab, children: [
              // Password History
              _history.isEmpty
                  ? const Center(child: Text('No password history'))
                  : ListView.builder(
                      itemCount: _history.length,
                      itemBuilder: (ctx, i) {
                        final h = _history[i];
                        return ListTile(
                          leading: const Icon(Icons.lock_clock),
                          title: Text('Changed by ${h['changed_by'] ?? '?'}'),
                          subtitle: Text(_fmtTs(h['changed_at'])),
                        );
                      },
                    ),
              // Versions
              _versions.isEmpty
                  ? const Center(child: Text('No versions'))
                  : ListView.builder(
                      itemCount: _versions.length,
                      itemBuilder: (ctx, i) {
                        final v = _versions[i];
                        return ListTile(
                          leading: const Icon(Icons.history),
                          title: Text('v${v['version_num']} — ${v['changed_by'] ?? '?'}'),
                          subtitle: Text(_fmtTs(v['changed_at'])),
                          trailing: TextButton(
                            onPressed: () => _restoreVersion(v['id'] as int),
                            child: const Text('Restore'),
                          ),
                        );
                      },
                    ),
            ]),
    );
  }

  String _fmtTs(dynamic ts) {
    if (ts == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch((ts as int) * 1000);
    return '${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')} '
           '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
  }

  @override
  void dispose() { _tab.dispose(); super.dispose(); }
}
