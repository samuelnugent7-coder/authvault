import 'package:flutter/material.dart';
import '../services/api_service.dart';

class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key});
  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  final _api = ApiService();
  List<Map<String, dynamic>> _sessions = [];
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
      final s = await _api.getSessions();
      setState(() { _sessions = s; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _revoke(int id) async {
    try {
      await _api.revokeSession(id);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Active Sessions'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
              : _sessions.isEmpty
                  ? const Center(child: Text('No sessions found.'))
                  : ListView.separated(
                      itemCount: _sessions.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final s = _sessions[i];
                        final revoked = s['revoked'] as bool? ?? false;
                        return ListTile(
                          leading: Icon(
                            Icons.computer,
                            color: revoked ? Colors.grey : Colors.green,
                          ),
                          title: Text(s['device'] ?? 'Unknown device',
                              style: TextStyle(
                                  color: revoked ? Colors.grey : null,
                                  decoration: revoked ? TextDecoration.lineThrough : null)),
                          subtitle: Text('IP: ${s['ip'] ?? '?'}\nLast seen: ${_formatTime(s['last_seen'])}'),
                          isThreeLine: true,
                          trailing: revoked
                              ? const Chip(label: Text('Revoked'))
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (s['fp_flagged'] == true)
                                      Tooltip(
                                        message: 'Device fingerprint changed — possible credential sharing or account takeover',
                                        child: Chip(
                                          avatar: const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.white),
                                          label: const Text('FP Changed', style: TextStyle(fontSize: 11, color: Colors.white)),
                                          backgroundColor: Colors.orange,
                                          padding: EdgeInsets.zero,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      ),
                                    IconButton(
                                      icon: const Icon(Icons.logout, color: Colors.red),
                                      tooltip: 'Revoke session',
                                      onPressed: () => _revoke(s['id'] as int),
                                    ),
                                  ],
                                ),
                        );
                      },
                    ),
    );
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
