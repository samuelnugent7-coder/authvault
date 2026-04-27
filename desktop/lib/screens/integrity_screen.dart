import 'package:flutter/material.dart';
import '../services/api_service.dart';

class IntegrityScreen extends StatefulWidget {
  const IntegrityScreen({super.key});
  @override
  State<IntegrityScreen> createState() => _IntegrityScreenState();
}

class _IntegrityScreenState extends State<IntegrityScreen> {
  final _api = ApiService();
  Map<String, dynamic>? _report;
  bool _loading = false;

  Future<void> _run() async {
    setState(() { _loading = true; _report = null; });
    try { _report = await _api.runIntegrityCheck(); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
    finally { setState(() => _loading = false); }
  }

  @override
  Widget build(BuildContext context) {
    final failures = (_report?['failures'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    return Scaffold(
      appBar: AppBar(title: const Text('Data Integrity Check')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
            'Scans all encrypted fields to verify they can be decrypted with the current key. '
            'Run this after key changes or to detect corruption.',
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            icon: const Icon(Icons.security),
            label: const Text('Run Integrity Check'),
            onPressed: _loading ? null : _run,
          ),
          if (_loading) const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()),
          if (_report != null) ...[
            const SizedBox(height: 16),
            Card(
              color: failures.isEmpty ? Colors.green[50] : Colors.red[50],
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Icon(failures.isEmpty ? Icons.check_circle : Icons.error,
                    color: failures.isEmpty ? Colors.green : Colors.red),
                  const SizedBox(width: 8),
                  Text(
                    failures.isEmpty
                        ? 'All ${_report!['total_checked']} fields OK'
                        : '${_report!['failed_count']} failures in ${_report!['total_checked']} fields',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ]),
              ),
            ),
            if (failures.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Failures:', style: TextStyle(fontWeight: FontWeight.bold)),
              ...failures.map((f) => ListTile(
                dense: true,
                leading: const Icon(Icons.warning, color: Colors.red),
                title: Text('${f['table']}.${f['field']} (id=${f['id']})'),
                subtitle: Text(f['error'] as String? ?? ''),
              )),
            ],
          ],
        ]),
      ),
    );
  }
}
