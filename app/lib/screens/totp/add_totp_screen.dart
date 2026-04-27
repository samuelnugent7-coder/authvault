import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../models/totp_entry.dart';
import '../../services/api_service.dart';

class AddTotpScreen extends StatefulWidget {
  final TotpEntry? existing;
  const AddTotpScreen({super.key, this.existing});
  @override
  State<AddTotpScreen> createState() => _AddTotpScreenState();
}

class _AddTotpScreenState extends State<AddTotpScreen> {
  final _nameCtrl = TextEditingController();
  final _issuerCtrl = TextEditingController();
  final _secretCtrl = TextEditingController();
  final _durationCtrl = TextEditingController(text: '30');
  final _lengthCtrl = TextEditingController(text: '6');
  int _hashAlgo = 0;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    if (_isEdit) {
      final e = widget.existing!;
      _nameCtrl.text = e.name;
      _issuerCtrl.text = e.issuer;
      _secretCtrl.text = e.secret;
      _durationCtrl.text = e.duration.toString();
      _lengthCtrl.text = e.length.toString();
      _hashAlgo = e.hashAlgo;
    }
  }

  @override
  void dispose() {
    for (final c in [_nameCtrl, _issuerCtrl, _secretCtrl, _durationCtrl, _lengthCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _scanQr() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _QrScanner()),
    );
    if (result == null) return;
    // Parse otpauth://totp/LABEL?secret=SECRET&issuer=ISSUER&...
    try {
      final uri = Uri.parse(result);
      final label = Uri.decodeComponent(uri.pathSegments.last);
      final issuer = uri.queryParameters['issuer'] ?? '';
      final secret = uri.queryParameters['secret'] ?? '';
      final period = int.tryParse(uri.queryParameters['period'] ?? '30') ?? 30;
      final digits = int.tryParse(uri.queryParameters['digits'] ?? '6') ?? 6;
      final algoStr = (uri.queryParameters['algorithm'] ?? 'SHA1').toUpperCase();
      final algo = algoStr == 'SHA256' ? 1 : algoStr == 'SHA512' ? 2 : 0;

      setState(() {
        _nameCtrl.text = label;
        _issuerCtrl.text = issuer;
        _secretCtrl.text = secret;
        _durationCtrl.text = period.toString();
        _lengthCtrl.text = digits.toString();
        _hashAlgo = algo;
      });
    } catch (e) {
      setState(() => _error = 'Invalid QR code: $e');
    }
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    final secret = _secretCtrl.text.trim().toUpperCase().replaceAll(' ', '');
    if (name.isEmpty || secret.isEmpty) {
      setState(() => _error = 'Name and secret are required');
      return;
    }

    setState(() { _saving = true; _error = null; });
    try {
      final api = context.read<ApiService>();
      final entry = TotpEntry(
        id: widget.existing?.id,
        name: name,
        issuer: _issuerCtrl.text.trim(),
        secret: secret,
        duration: int.tryParse(_durationCtrl.text) ?? 30,
        length: int.tryParse(_lengthCtrl.text) ?? 6,
        hashAlgo: _hashAlgo,
      );
      if (_isEdit) {
        await api.updateTotp(entry);
      } else {
        await api.createTotp(entry);
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
        title: Text(_isEdit ? 'Edit TOTP' : 'Add TOTP'),
        actions: [
          if (!_isEdit && (Platform.isAndroid || Platform.isIOS))
            IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              tooltip: 'Scan QR',
              onPressed: _scanQr,
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _field(_nameCtrl, 'Account Name', required: true),
            const SizedBox(height: 12),
            _field(_issuerCtrl, 'Issuer (optional)'),
            const SizedBox(height: 12),
            _field(_secretCtrl, 'Secret Key', required: true, mono: true),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _field(_durationCtrl, 'Period (seconds)', numeric: true)),
                const SizedBox(width: 12),
                Expanded(child: _field(_lengthCtrl, 'Digits', numeric: true)),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: _hashAlgo,
              decoration: const InputDecoration(labelText: 'Hash Algorithm', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 0, child: Text('SHA-1 (default)')),
                DropdownMenuItem(value: 1, child: Text('SHA-256')),
                DropdownMenuItem(value: 2, child: Text('SHA-512')),
              ],
              onChanged: (v) => setState(() => _hashAlgo = v ?? 0),
            ),
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
                label: Text(_isEdit ? 'Update' : 'Add Entry'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label, {
    bool required = false,
    bool mono = false,
    bool numeric = false,
  }) =>
      TextField(
        controller: ctrl,
        decoration: InputDecoration(
          labelText: label + (required ? ' *' : ''),
          border: const OutlineInputBorder(),
        ),
        style: mono ? const TextStyle(fontFamily: 'monospace') : null,
        keyboardType: numeric ? TextInputType.number : null,
        autocorrect: false,
      );
}

class _QrScanner extends StatefulWidget {
  const _QrScanner();
  @override
  State<_QrScanner> createState() => _QrScannerState();
}

class _QrScannerState extends State<_QrScanner> {
  bool _found = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR Code')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_found) return;
          final barcode = capture.barcodes.firstOrNull;
          if (barcode?.rawValue != null) {
            _found = true;
            Navigator.of(context).pop(barcode!.rawValue);
          }
        },
      ),
    );
  }
}
