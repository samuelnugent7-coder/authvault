import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';

class SSHScreen extends StatefulWidget {
  const SSHScreen({super.key});
  @override
  State<SSHScreen> createState() => _SSHScreenState();
}

class _SSHScreenState extends State<SSHScreen> {
  final _api = ApiService();
  List<Map<String, dynamic>> _keys = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final k = await _api.getSSHKeys();
      setState(() { _keys = k; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _showAddEdit([Map<String, dynamic>? key]) async {
    final nameCtrl = TextEditingController(text: key?['name'] ?? '');
    final pubCtrl = TextEditingController(text: key?['public_key'] ?? '');
    final privCtrl = TextEditingController(text: key?['private_key'] ?? '');
    final commentCtrl = TextEditingController(text: key?['comment'] ?? '');

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(key == null ? 'Add SSH Key' : 'Edit SSH Key'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name')),
              const SizedBox(height: 8),
              TextField(controller: pubCtrl, decoration: const InputDecoration(labelText: 'Public Key'),
                  maxLines: 3),
              const SizedBox(height: 8),
              TextField(controller: privCtrl, decoration: const InputDecoration(labelText: 'Private Key (optional)'),
                  maxLines: 5, obscureText: false),
              const SizedBox(height: 8),
              TextField(controller: commentCtrl, decoration: const InputDecoration(labelText: 'Comment')),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );

    if (result != true) return;
    final data = {
      'name': nameCtrl.text,
      'public_key': pubCtrl.text,
      'private_key': privCtrl.text,
      'comment': commentCtrl.text,
    };
    try {
      if (key == null) {
        await _api.createSSHKey(data);
      } else {
        await _api.updateSSHKey(key['id'] as int, data);
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _delete(int id, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete SSH Key'),
        content: Text('Delete "$name"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _api.deleteSSHKey(id);
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
        title: const Text('SSH Keys'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          IconButton(icon: const Icon(Icons.add), onPressed: () => _showAddEdit()),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
              : _keys.isEmpty
                  ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.key_off, size: 64, color: Colors.grey),
                      const SizedBox(height: 16),
                      const Text('No SSH keys stored.'),
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Add SSH Key'),
                        onPressed: () => _showAddEdit(),
                      ),
                    ]))
                  : ListView.separated(
                      itemCount: _keys.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final k = _keys[i];
                        return ListTile(
                          leading: const Icon(Icons.key, color: Colors.amber),
                          title: Text(k['name'] ?? ''),
                          subtitle: Text(k['comment'] ?? k['public_key'] ?? ''),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                              icon: const Icon(Icons.copy),
                              tooltip: 'Copy public key',
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: k['public_key'] ?? ''));
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Public key copied')));
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit),
                              onPressed: () => _showAddEdit(k),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () => _delete(k['id'] as int, k['name'] ?? ''),
                            ),
                          ]),
                        );
                      },
                    ),
    );
  }
}
