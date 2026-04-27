import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';

class ApiKeysScreen extends StatefulWidget {
  const ApiKeysScreen({super.key});
  @override
  State<ApiKeysScreen> createState() => _ApiKeysScreenState();
}

class _ApiKeysScreenState extends State<ApiKeysScreen> {
  final _api = ApiService();
  List<Map<String, dynamic>> _keys = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try { _keys = await _api.getApiKeys(); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
    finally { setState(() => _loading = false); }
  }

  Future<void> _create() async {
    final name = await _nameDialog();
    if (name == null || name.isEmpty) return;
    try {
      final k = await _api.createApiKey(name);
      if (!mounted) return;
      final rawKey = k['raw_key'] as String? ?? '';
      await showDialog(context: context, builder: (ctx) => AlertDialog(
        title: const Text('API Key Created'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Copy this key now — it will not be shown again.', style: TextStyle(color: Colors.orange)),
          const SizedBox(height: 8),
          SelectableText(rawKey, style: const TextStyle(fontFamily: 'monospace')),
        ]),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: rawKey));
              Navigator.pop(ctx);
            },
            child: const Text('Copy & Close'),
          ),
        ],
      ));
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<String?> _nameDialog() async {
    final ctrl = TextEditingController();
    return showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('New API Key'),
      content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Name / Description')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Create')),
      ],
    ));
  }

  Future<void> _revoke(Map<String, dynamic> k) async {
    await _api.revokeApiKey(k['id'] as int);
    _load();
  }

  Future<void> _delete(Map<String, dynamic> k) async {
    await _api.deleteApiKey(k['id'] as int);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('API Keys'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      floatingActionButton: FloatingActionButton(onPressed: _create, child: const Icon(Icons.add)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _keys.isEmpty
              ? const Center(child: Text('No API keys. Tap + to create one.'))
              : ListView.builder(
                  itemCount: _keys.length,
                  itemBuilder: (ctx, i) {
                    final k = _keys[i];
                    final revoked = k['revoked'] == true || k['revoked'] == 1;
                    return ListTile(
                      leading: Icon(Icons.vpn_key, color: revoked ? Colors.grey : Colors.blue),
                      title: Text(k['name'] as String? ?? ''),
                      subtitle: Text('${k['key_prefix'] ?? ''}...  '
                          '${revoked ? "REVOKED" : "Active"}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (!revoked)
                          IconButton(
                            icon: const Icon(Icons.block, color: Colors.orange),
                            tooltip: 'Revoke',
                            onPressed: () => _revoke(k),
                          ),
                        IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          tooltip: 'Delete',
                          onPressed: () => _delete(k),
                        ),
                      ]),
                    );
                  },
                ),
    );
  }
}
