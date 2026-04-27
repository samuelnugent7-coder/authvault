import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/safe_node.dart';
import '../../services/api_service.dart';

class RecordViewScreen extends StatefulWidget {
  final int folderId;
  final String folderName;
  final SafeRecord? existing;

  const RecordViewScreen({
    super.key,
    required this.folderId,
    required this.folderName,
    this.existing,
  });

  @override
  State<RecordViewScreen> createState() => _RecordViewScreenState();
}

class _RecordViewScreenState extends State<RecordViewScreen> {
  final _nameCtrl = TextEditingController();
  final _loginCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final List<_ItemRow> _items = [];
  bool _saving = false;
  bool _obscurePass = true;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    if (_isEdit) {
      final r = widget.existing!;
      _nameCtrl.text = r.name;
      _loginCtrl.text = r.login;
      _passCtrl.text = r.password;
      for (final item in r.items) {
        _items.add(_ItemRow(
          nameCtrl: TextEditingController(text: item.name),
          contentCtrl: TextEditingController(text: item.content),
          id: item.id,
        ));
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _loginCtrl.dispose();
    _passCtrl.dispose();
    for (final r in _items) {
      r.nameCtrl.dispose();
      r.contentCtrl.dispose();
    }
    super.dispose();
  }

  void _addItem() {
    setState(() => _items.add(_ItemRow(
          nameCtrl: TextEditingController(),
          contentCtrl: TextEditingController(),
        )));
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Record name is required');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final api = context.read<ApiService>();
      final items = _items
          .where((r) => r.nameCtrl.text.trim().isNotEmpty)
          .map((r) => SafeItem(
                id: r.id,
                name: r.nameCtrl.text.trim(),
                content: r.contentCtrl.text.trim(),
              ))
          .toList();

      final record = SafeRecord(
        id: widget.existing?.id,
        folderId: widget.folderId,
        name: name,
        login: _loginCtrl.text.trim(),
        password: _passCtrl.text.trim(),
        items: items,
      );

      if (_isEdit) {
        await api.updateRecord(record);
      } else {
        await api.createRecord(record);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() { _error = e.toString(); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_isEdit ? 'Edit Record' : 'New Record'),
            if (widget.folderName.isNotEmpty)
              Text(widget.folderName, style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _saving ? null : _save,
            tooltip: 'Save',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _field(_nameCtrl, 'Record Name', required: true),
            const SizedBox(height: 12),
            _field(_loginCtrl, 'Login / Username'),
            const SizedBox(height: 12),
            TextField(
              controller: _passCtrl,
              obscureText: _obscurePass,
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(_obscurePass ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _obscurePass = !_obscurePass),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () => _copy(context, _passCtrl.text),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Text('Custom Fields', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                TextButton.icon(
                  onPressed: _addItem,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Field'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ..._items.asMap().entries.map((entry) {
              final i = entry.key;
              final row = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: row.nameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Field Name',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: row.contentCtrl,
                        decoration: InputDecoration(
                          labelText: 'Value',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.copy, size: 16),
                            onPressed: () => _copy(context, row.contentCtrl.text),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent, size: 20),
                      onPressed: () => setState(() => _items.removeAt(i)),
                    ),
                  ],
                ),
              );
            }),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save),
                label: Text(_isEdit ? 'Update Record' : 'Save Record'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label, {bool required = false}) => TextField(
        controller: ctrl,
        decoration: InputDecoration(
          labelText: label + (required ? ' *' : ''),
          border: const OutlineInputBorder(),
          suffixIcon: label.toLowerCase().contains('login')
              ? IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => _copy(context, ctrl.text),
                )
              : null,
        ),
      );

  void _copy(BuildContext context, String text) {
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied!'), duration: Duration(seconds: 1)),
    );
  }
}

class _ItemRow {
  final int? id;
  final TextEditingController nameCtrl;
  final TextEditingController contentCtrl;

  _ItemRow({required this.nameCtrl, required this.contentCtrl, this.id});
}
