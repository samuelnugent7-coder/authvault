import 'package:flutter/material.dart';
import '../services/api_service.dart';

class TagsScreen extends StatefulWidget {
  const TagsScreen({super.key});
  @override
  State<TagsScreen> createState() => _TagsScreenState();
}

class _TagsScreenState extends State<TagsScreen> {
  final _api = ApiService();
  List<Map<String, dynamic>> _tags = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _tags = await _api.getTags();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  Color _hexColor(String? hex) {
    if (hex == null || hex.isEmpty) return Colors.blue;
    final h = hex.startsWith('#') ? hex.substring(1) : hex;
    try { return Color(int.parse('FF$h', radix: 16)); } catch (_) { return Colors.blue; }
  }

  Future<void> _showEditor({Map<String, dynamic>? tag}) async {
    final nameCtrl = TextEditingController(text: tag?['name'] ?? '');
    var colorHex = tag?['color'] ?? '#4CAF50';
    final colorCtrl = TextEditingController(text: colorHex);

    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(tag == null ? 'New Tag' : 'Edit Tag'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name')),
        const SizedBox(height: 12),
        TextField(controller: colorCtrl, decoration: const InputDecoration(
          labelText: 'Color (hex e.g. #4CAF50)',
          prefixIcon: Icon(Icons.color_lens),
        )),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () {
          colorHex = colorCtrl.text.trim();
          Navigator.pop(ctx, true);
        }, child: const Text('Save')),
      ],
    ));
    if (ok != true) return;

    try {
      if (tag == null) {
        await _api.createTag(nameCtrl.text.trim(), colorHex);
      } else {
        await _api.updateTag(tag['id'] as int, nameCtrl.text.trim(), colorHex);
      }
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete(int id) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete Tag?'),
      content: const Text('The tag will be removed from all records.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
      ],
    ));
    if (ok != true) return;
    try {
      await _api.deleteTag(id);
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tags'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditor(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _tags.isEmpty
              ? const Center(child: Text('No tags yet. Create one with +'))
              : ListView.builder(
                  itemCount: _tags.length,
                  itemBuilder: (ctx, i) {
                    final t = _tags[i];
                    final c = _hexColor(t['color']);
                    return ListTile(
                      leading: CircleAvatar(backgroundColor: c,
                          child: Text((t['name'] as String?)?.substring(0,1).toUpperCase() ?? '?',
                              style: const TextStyle(color: Colors.white))),
                      title: Text(t['name'] ?? ''),
                      subtitle: Text(t['color'] ?? ''),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(icon: const Icon(Icons.edit), onPressed: () => _showEditor(tag: t)),
                        IconButton(icon: const Icon(Icons.delete, color: Colors.red),
                            onPressed: () => _delete(t['id'] as int)),
                      ]),
                    );
                  },
                ),
    );
  }
}
