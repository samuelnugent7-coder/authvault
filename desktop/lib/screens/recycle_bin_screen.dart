import 'package:flutter/material.dart';
import '../services/api_service.dart';

class RecycleBinScreen extends StatefulWidget {
  const RecycleBinScreen({super.key});
  @override
  State<RecycleBinScreen> createState() => _RecycleBinScreenState();
}

class _RecycleBinScreenState extends State<RecycleBinScreen> {
  final _api = ApiService();
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _items = await _api.getRecycleBin();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _restore(Map<String, dynamic> item) async {
    try {
      await _api.restoreBinItem(item['id'] as int);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Restored')));
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Permanently Delete?'),
      content: const Text('This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
      ],
    ));
    if (ok != true) return;
    await _api.deleteBinItem(item['id'] as int);
    _load();
  }

  Future<void> _emptyBin() async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Empty Recycle Bin?'),
      content: const Text('All items will be permanently deleted.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Empty', style: TextStyle(color: Colors.red))),
      ],
    ));
    if (ok != true) return;
    await _api.emptyRecycleBin();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recycle Bin'),
        actions: [
          if (_items.isNotEmpty)
            TextButton.icon(
              icon: const Icon(Icons.delete_forever, color: Colors.red),
              label: const Text('Empty', style: TextStyle(color: Colors.red)),
              onPressed: _emptyBin,
            ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? const Center(child: Text('Recycle bin is empty'))
              : ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (ctx, i) {
                    final item = _items[i];
                    final type = item['item_type'] as String? ?? '';
                    final name = item['name'] ?? 'Unknown';
                    return ListTile(
                      leading: Icon(type == 'note' ? Icons.note : Icons.lock),
                      title: Text('$name'),
                      subtitle: Text(type),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          icon: const Icon(Icons.restore, color: Colors.green),
                          onPressed: () => _restore(item),
                          tooltip: 'Restore',
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_forever, color: Colors.red),
                          onPressed: () => _delete(item),
                          tooltip: 'Delete permanently',
                        ),
                      ]),
                    );
                  },
                ),
    );
  }
}
