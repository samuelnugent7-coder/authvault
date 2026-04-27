import 'package:flutter/material.dart';
import '../services/api_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _api = ApiService();
  Map<String, dynamic> _stats = {};
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try { _stats = await _api.getDashboard(); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
    finally { setState(() => _loading = false); }
  }

  Widget _statCard(String label, dynamic value, {IconData? icon, Color? color}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) Icon(icon, color: color ?? Colors.blue, size: 32),
          const SizedBox(height: 8),
          Text('$value', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          Text(label, style: const TextStyle(color: Colors.grey)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recent = (_stats['recent_audit'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                LayoutBuilder(builder: (ctx, constraints) {
                  final cols = constraints.maxWidth > 600 ? 4 : 2;
                  return GridView.count(
                    shrinkWrap: true, crossAxisCount: cols,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisSpacing: 8, mainAxisSpacing: 8,
                    childAspectRatio: 1.2,
                    children: [
                      _statCard('Records', _stats['records'] ?? 0, icon: Icons.lock),
                      _statCard('TOTP', _stats['totp'] ?? 0, icon: Icons.qr_code),
                      _statCard('SSH Keys', _stats['ssh_keys'] ?? 0, icon: Icons.key),
                      _statCard('Notes', _stats['notes'] ?? 0, icon: Icons.note),
                      _statCard('Tags', _stats['tags'] ?? 0, icon: Icons.label),
                      _statCard('API Keys', _stats['api_keys'] ?? 0, icon: Icons.vpn_key),
                      _statCard('Sessions', _stats['active_sessions'] ?? 0, icon: Icons.devices),
                      _statCard('Health', '${_stats['health_score'] ?? 0}%',
                        icon: Icons.favorite,
                        color: (_stats['health_score'] as int? ?? 0) >= 80 ? Colors.green : Colors.orange),
                    ],
                  );
                }),
                if (recent.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('Recent Activity', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ...recent.map((e) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.history, size: 20),
                    title: Text('${e['action'] ?? ''} — ${e['username'] ?? ''}'),
                    subtitle: Text('${e['ip'] ?? ''} ${e['details'] ?? ''}'),
                  )),
                ],
              ]),
            ),
    );
  }
}
