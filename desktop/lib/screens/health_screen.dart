import 'package:flutter/material.dart';
import '../services/api_service.dart';

class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key});
  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  final _api = ApiService();
  Map<String, dynamic>? _report;
  bool _loading = false;
  bool _hibp = false;
  String? _error;

  Future<void> _scan() async {
    setState(() { _loading = true; _error = null; _report = null; });
    try {
      final r = await _api.getPasswordHealth(hibp: _hibp);
      setState(() { _report = r; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = (_report?['results'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    return Scaffold(
      appBar: AppBar(title: const Text('Password Health')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Text('Check HaveIBeenPwned (requires internet):'),
              const SizedBox(width: 8),
              Switch(value: _hibp, onChanged: (v) => setState(() => _hibp = v)),
              const Spacer(),
              ElevatedButton.icon(
                icon: const Icon(Icons.health_and_safety),
                label: const Text('Scan Now'),
                onPressed: _loading ? null : _scan,
              ),
            ]),
            const SizedBox(height: 16),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            if (_report != null) ...[
              _summaryRow('Total scanned', _report!['total_items']),
              _summaryRow('Issues found', _report!['issue_count'], color: Colors.orange),
              _summaryRow('Weak passwords', _report!['weak_count'], color: Colors.orange),
              _summaryRow('Reused passwords', _report!['reused_count'], color: Colors.orange),
              _summaryRow('Old passwords (>90d)', _report!['old_count'], color: Colors.blue),
              _summaryRow('Breached (HIBP)', _report!['breached_count'], color: Colors.red),
              const Divider(),
              const Text('Affected records:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
            ],
            if (results.isNotEmpty)
              Expanded(
                child: ListView.separated(
                  itemCount: results.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final r = results[i];
                    final issues = (r['issues'] as List?)?.cast<String>() ?? [];
                    return ListTile(
                      leading: const Icon(Icons.warning_amber, color: Colors.orange),
                      title: Text(r['record_name'] ?? ''),
                      subtitle: Text(issues.join(' • ')),
                      trailing: Text(r['folder_name'] ?? '',
                          style: Theme.of(context).textTheme.bodySmall),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _summaryRow(String label, dynamic value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Text(label),
        const Spacer(),
        Text('${value ?? 0}',
            style: TextStyle(fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }
}
