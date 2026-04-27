import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/safe_node.dart';

class RecordView extends StatefulWidget {
  final SafeRecord record;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const RecordView({
    super.key,
    required this.record,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<RecordView> createState() => _RecordViewState();
}

class _RecordViewState extends State<RecordView> {
  bool _showPassword = false;

  void _copy(String value, String label) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$label copied'),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
      width: 240,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.record;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(r.title),
        actions: [
          IconButton(icon: const Icon(Icons.edit_outlined), onPressed: widget.onEdit, tooltip: 'Edit'),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            onPressed: widget.onDelete,
            tooltip: 'Delete',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // Header card
          Card(
            color: cs.primaryContainer.withOpacity(0.3),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: cs.primaryContainer,
                  child: Text(
                    (r.title.isEmpty ? '?' : r.title[0]).toUpperCase(),
                    style: TextStyle(fontSize: 20, color: cs.onPrimaryContainer, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 16),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.title, style: Theme.of(context).textTheme.titleLarge),
                  if (r.url.isNotEmpty)
                    Text(r.url,
                        style: TextStyle(color: cs.primary, fontSize: 13)),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          if (r.username.isNotEmpty) _FieldTile(
            label: 'Username',
            value: r.username,
            icon: Icons.person_outline,
            onCopy: () => _copy(r.username, 'Username'),
          ),
          if (r.password.isNotEmpty) _FieldTile(
            label: 'Password',
            value: _showPassword ? r.password : '••••••••••••',
            icon: Icons.lock_outline,
            onCopy: () => _copy(r.password, 'Password'),
            trailing: IconButton(
              icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility, size: 18),
              onPressed: () => setState(() => _showPassword = !_showPassword),
            ),
          ),
          if (r.url.isNotEmpty) _FieldTile(
            label: 'URL',
            value: r.url,
            icon: Icons.link_outlined,
            onCopy: () => _copy(r.url, 'URL'),
          ),
          if (r.notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Notes', style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 4),
            Card(
              color: cs.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(r.notes),
              ),
            ),
          ],
          if (r.items.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Custom Fields',
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 4),
            ...r.items.map((item) => _FieldTile(
              label: item.label,
              value: item.value,
              icon: Icons.label_outline,
              onCopy: () => _copy(item.value, item.label),
            )),
          ],
        ],
      ),
    );
  }
}

class _FieldTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onCopy;
  final Widget? trailing;

  const _FieldTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.onCopy,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: Icon(icon, size: 20, color: cs.onSurfaceVariant),
      title: Text(label,
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      subtitle: SelectableText(value,
          style: const TextStyle(fontSize: 15)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (trailing != null) trailing!,
        IconButton(
          icon: const Icon(Icons.copy, size: 16),
          tooltip: 'Copy $label',
          onPressed: onCopy,
        ),
      ]),
    );
  }
}
