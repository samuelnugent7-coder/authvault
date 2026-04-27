import 'package:flutter/material.dart';
import '../services/api_service.dart';

class DuressAdminScreen extends StatefulWidget {
  const DuressAdminScreen({super.key});
  @override
  State<DuressAdminScreen> createState() => _DuressAdminScreenState();
}

class _DuressAdminScreenState extends State<DuressAdminScreen> {
  final _api = ApiService();
  final _passCtrl = TextEditingController();
  final _pass2Ctrl = TextEditingController();
  List<Map<String, dynamic>> _folders = [];
  bool _loading = true, _saving = false;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try { _folders = await _api.getDecoyFolders(); }
    catch (_) {}
    setState(() => _loading = false);
  }

  Future<void> _savePassword() async {
    if (_passCtrl.text.isEmpty) return;
    if (_passCtrl.text != _pass2Ctrl.text) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Passwords do not match')));
      return;
    }
    setState(() => _saving = true);
    try {
      await _api.setDuressPassword(_passCtrl.text);
      _passCtrl.clear(); _pass2Ctrl.clear();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Duress password set')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally { setState(() => _saving = false); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Duress / Decoy Vault')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text(
                  'Duress Mode: When a user logs in with the duress password, '
                  'only decoy folders are shown. Set the duress password below, '
                  'then mark which folders are "decoy" (safe to reveal under coercion).',
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 16),
                const Text('Set Duress Password', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                TextField(controller: _passCtrl, obscureText: true,
                  decoration: const InputDecoration(labelText: 'New Duress Password')),
                const SizedBox(height: 8),
                TextField(controller: _pass2Ctrl, obscureText: true,
                  decoration: const InputDecoration(labelText: 'Confirm Duress Password')),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: _saving ? null : _savePassword,
                  child: const Text('Set Duress Password'),
                ),
                const SizedBox(height: 24),
                const Text('Decoy Folders (shown on duress login)',
                  style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const Text('Use the Folders panel to create decoy folders, then mark them here.',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(height: 8),
                if (_folders.isEmpty)
                  const Text('No decoy folders set.')
                else
                  ..._folders.map((f) => ListTile(
                    leading: const Icon(Icons.folder, color: Colors.orange),
                    title: Text(f['name'] as String? ?? ''),
                    trailing: IconButton(
                      icon: const Icon(Icons.remove_circle, color: Colors.red),
                      onPressed: () async {
                        await _api.setDecoyFolder(f['id'] as int, false);
                        _load();
                      },
                      tooltip: 'Remove decoy flag',
                    ),
                  )),
              ]),
            ),
    );
  }

  @override
  void dispose() { _passCtrl.dispose(); _pass2Ctrl.dispose(); super.dispose(); }
}
