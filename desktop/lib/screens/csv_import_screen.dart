import 'package:flutter/material.dart';
import 'dart:io';
import '../services/api_service.dart';

class CsvImportScreen extends StatefulWidget {
  const CsvImportScreen({super.key});
  @override
  State<CsvImportScreen> createState() => _CsvImportScreenState();
}

class _CsvImportScreenState extends State<CsvImportScreen> {
  final _api = ApiService();
  String _format = 'generic';
  String _csvContent = '';
  Map<String, dynamic>? _result;
  bool _importing = false;

  final _formats = ['bitwarden', '1password', 'lastpass', 'generic'];

  Future<void> _pickFile() async {
    // On Windows desktop, use a file dialog
    try {
      final result = await _pickFileDesktop();
      if (result != null) setState(() => _csvContent = result);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<String?> _pickFileDesktop() async {
    // Simple approach: show a text input dialog to paste CSV content
    final ctrl = TextEditingController(text: _csvContent);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste CSV Content'),
        content: SizedBox(
          width: 500, height: 300,
          child: TextField(
            controller: ctrl,
            maxLines: null,
            expands: true,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              hintText: 'Paste your CSV export here…',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _import() async {
    if (_csvContent.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No CSV content')));
      return;
    }
    setState(() { _importing = true; _result = null; });
    try {
      _result = await _api.importCsv(_csvContent, format: _format);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CSV Import')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Import passwords from another password manager.',
            style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _format,
            decoration: const InputDecoration(labelText: 'Source Format'),
            items: _formats.map((f) => DropdownMenuItem(value: f, child: Text(f))).toList(),
            onChanged: (v) => setState(() => _format = v!),
          ),
          const SizedBox(height: 16),
          Row(children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.paste),
              label: const Text('Paste CSV'),
              onPressed: _pickFile,
            ),
            const SizedBox(width: 8),
            if (_csvContent.isNotEmpty)
              Text('${_csvContent.split('\n').length} lines', style: const TextStyle(color: Colors.grey)),
          ]),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            icon: _importing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload),
            label: const Text('Import'),
            onPressed: _importing ? null : _import,
          ),
          if (_result != null) ...[
            const SizedBox(height: 16),
            Card(
              color: Colors.green[50],
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Imported: ${_result!['imported'] ?? 0} records', style: const TextStyle(fontWeight: FontWeight.bold)),
                  if (_result!['skipped'] != null) Text('Skipped: ${_result!['skipped']}'),
                  if (_result!['errors'] != null && (_result!['errors'] as List).isNotEmpty)
                    Text('Errors: ${(_result!['errors'] as List).length}', style: const TextStyle(color: Colors.red)),
                ]),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
