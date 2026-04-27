import 'package:flutter/material.dart';
import '../../models/totp_entry.dart';

class AddTotpDialog extends StatefulWidget {
  final TotpEntry? entry;
  const AddTotpDialog({super.key, this.entry});

  @override
  State<AddTotpDialog> createState() => _AddTotpDialogState();
}

class _AddTotpDialogState extends State<AddTotpDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _issuer;
  late final TextEditingController _secret;
  late int _duration;
  late int _length;
  late int _hashAlgo;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _name = TextEditingController(text: e?.name ?? '');
    _issuer = TextEditingController(text: e?.issuer ?? '');
    _secret = TextEditingController(text: e?.secret ?? '');
    _duration = e?.duration ?? 30;
    _length = e?.length ?? 6;
    _hashAlgo = e?.hashAlgo ?? 0;
  }

  @override
  void dispose() {
    _name.dispose(); _issuer.dispose(); _secret.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      TotpEntry(
        id: widget.entry?.id,
        name: _name.text.trim(),
        issuer: _issuer.text.trim(),
        secret: _secret.text.trim().toUpperCase().replaceAll(' ', ''),
        duration: _duration,
        length: _length,
        hashAlgo: _hashAlgo,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.entry != null;
    return AlertDialog(
      title: Text(isEdit ? 'Edit Entry' : 'Add TOTP Entry'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name *', border: OutlineInputBorder()),
              validator: (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _issuer,
              decoration: const InputDecoration(labelText: 'Issuer', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _secret,
              decoration: const InputDecoration(
                  labelText: 'Secret (Base32) *', border: OutlineInputBorder()),
              validator: (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  value: _duration,
                  decoration: const InputDecoration(labelText: 'Period', border: OutlineInputBorder()),
                  items: [30, 60]
                      .map((s) => DropdownMenuItem(value: s, child: Text('${s}s')))
                      .toList(),
                  onChanged: (v) => setState(() => _duration = v!),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  value: _length,
                  decoration: const InputDecoration(labelText: 'Digits', border: OutlineInputBorder()),
                  items: [6, 8]
                      .map((l) => DropdownMenuItem(value: l, child: Text('$l')))
                      .toList(),
                  onChanged: (v) => setState(() => _length = v!),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  value: _hashAlgo,
                  decoration: const InputDecoration(labelText: 'Algorithm', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('SHA-1')),
                    DropdownMenuItem(value: 1, child: Text('SHA-256')),
                    DropdownMenuItem(value: 2, child: Text('SHA-512')),
                  ],
                  onChanged: (v) => setState(() => _hashAlgo = v!),
                ),
              ),
            ]),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: Text(isEdit ? 'Save' : 'Add')),
      ],
    );
  }
}
