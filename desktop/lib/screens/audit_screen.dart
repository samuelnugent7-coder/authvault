import 'package:flutter/material.dart';
import '../services/api_service.dart';

class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});
  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  final _api = ApiService();
  List<Map<String, dynamic>> _logs = [];
  bool _loading = true;
  String? _error;
  int _limit = 100;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final logs = await _api.getAuditLogs(limit: _limit);
      setState(() { _logs = logs; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Audit Log'),
        actions: [
          DropdownButton<int>(
            value: _limit,
            underline: const SizedBox(),
            items: [50, 100, 250, 500].map((n) =>
              DropdownMenuItem(value: n, child: Text('$n entries'))).toList(),
            onChanged: (v) { if (v != null) { _limit = v; _load(); } },
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
              : _logs.isEmpty
                  ? const Center(child: Text('No audit logs found.'))
                  : ListView.separated(
                      itemCount: _logs.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final log = _logs[i];
                        final event = log['event'] as String? ?? '';
                        final icon = _iconFor(event);
                        final color = _colorFor(event);
                        return ListTile(
                          leading: Icon(icon, color: color),
                          title: Text(event, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
                          subtitle: Text(
                            '${log['username'] ?? ''} • ${log['ip'] ?? ''}\n${log['details'] ?? ''}',
                          ),
                          trailing: Text(
                            _formatTime(log['created_at']),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          isThreeLine: true,
                        );
                      },
                    ),
    );
  }

  IconData _iconFor(String event) {
    if (event.contains('failed')) return Icons.error_outline;
    if (event.contains('login')) return Icons.login;
    if (event.contains('logout')) return Icons.logout;
    if (event.contains('new_ip')) return Icons.location_on;
    if (event.contains('revoked')) return Icons.block;
    return Icons.info_outline;
  }

  Color _colorFor(String event) {
    if (event.contains('failed')) return Colors.red;
    if (event.contains('new_ip')) return Colors.orange;
    if (event.contains('revoked')) return Colors.deepOrange;
    return Colors.green;
  }

  String _formatTime(dynamic ts) {
    if (ts == null) return '';
    try {
      final dt = DateTime.fromMillisecondsSinceEpoch((ts as int) * 1000, isUtc: true).toLocal();
      return '${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')} '
          '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
    } catch (_) { return ts.toString(); }
  }
}
