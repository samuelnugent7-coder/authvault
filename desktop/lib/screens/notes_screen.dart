import 'package:flutter/material.dart';
import '../services/api_service.dart';

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});
  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  final _api = ApiService();
  List<Map<String, dynamic>> _notes = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try { _notes = await _api.getNotes(); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
    finally { setState(() => _loading = false); }
  }

  Future<void> _openNote([Map<String, dynamic>? existing]) async {
    final result = await Navigator.push<bool>(context,
      MaterialPageRoute(builder: (_) => NoteEditScreen(note: existing)));
    if (result == true) _load();
  }

  Future<void> _delete(Map<String, dynamic> note) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete Note?'),
      content: const Text('Moves to recycle bin.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
      ],
    ));
    if (ok != true) return;
    await _api.deleteNote(note['id'] as int);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Secure Notes'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openNote(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _notes.isEmpty
              ? const Center(child: Text('No notes. Tap + to add one.'))
              : ListView.builder(
                  itemCount: _notes.length,
                  itemBuilder: (ctx, i) {
                    final n = _notes[i];
                    final tags = (n['tags'] as List?)?.cast<String>() ?? [];
                    return ListTile(
                      leading: const Icon(Icons.note),
                      title: Text(n['title'] as String? ?? ''),
                      subtitle: tags.isEmpty ? null : Wrap(
                        spacing: 4,
                        children: tags.map((t) => Chip(label: Text(t), visualDensity: VisualDensity.compact)).toList(),
                      ),
                      trailing: IconButton(icon: const Icon(Icons.delete), onPressed: () => _delete(n)),
                      onTap: () => _openNote(n),
                    );
                  },
                ),
    );
  }
}

class NoteEditScreen extends StatefulWidget {
  final Map<String, dynamic>? note;
  const NoteEditScreen({super.key, this.note});
  @override
  State<NoteEditScreen> createState() => _NoteEditScreenState();
}

class _NoteEditScreenState extends State<NoteEditScreen> {
  final _api = ApiService();
  final _titleCtrl = TextEditingController();
  final _contentCtrl = TextEditingController();
  final _tagsCtrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.note != null) {
      _titleCtrl.text = widget.note!['title'] as String? ?? '';
      _contentCtrl.text = widget.note!['content'] as String? ?? '';
      final tags = (widget.note!['tags'] as List?)?.cast<String>() ?? [];
      _tagsCtrl.text = tags.join(', ');
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose(); _contentCtrl.dispose(); _tagsCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_titleCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Title required')));
      return;
    }
    setState(() => _saving = true);
    final tags = _tagsCtrl.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    final body = {'title': _titleCtrl.text, 'content': _contentCtrl.text, 'tags': tags};
    try {
      if (widget.note == null) {
        await _api.createNote(body);
      } else {
        await _api.updateNote(widget.note!['id'] as int, body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.note == null ? 'New Note' : 'Edit Note'),
        actions: [
          TextButton(onPressed: _saving ? null : _save, child: const Text('Save')),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          TextField(controller: _titleCtrl, decoration: const InputDecoration(labelText: 'Title')),
          const SizedBox(height: 8),
          TextField(
            controller: _contentCtrl,
            decoration: const InputDecoration(labelText: 'Content'),
            maxLines: 10,
            minLines: 4,
          ),
          const SizedBox(height: 8),
          TextField(controller: _tagsCtrl, decoration: const InputDecoration(
            labelText: 'Tags (comma separated)',
            hintText: 'work, personal, finance',
          )),
        ]),
      ),
    );
  }
}
