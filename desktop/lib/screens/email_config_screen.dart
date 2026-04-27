import 'package:flutter/material.dart';
import '../services/api_service.dart';

class EmailConfigScreen extends StatefulWidget {
  const EmailConfigScreen({super.key});
  @override
  State<EmailConfigScreen> createState() => _EmailConfigScreenState();
}

class _EmailConfigScreenState extends State<EmailConfigScreen> {
  final _api = ApiService();
  Map<String, dynamic> _cfg = {};
  bool _loading = true, _saving = false;

  final _smtpHostCtrl = TextEditingController();
  final _smtpPortCtrl = TextEditingController();
  final _smtpUserCtrl = TextEditingController();
  final _smtpPassCtrl = TextEditingController();
  final _fromCtrl = TextEditingController();
  final _alertToCtrl = TextEditingController();
  bool _enabled = false;
  bool _smtpTls = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _cfg = await _api.getEmailConfig();
      _enabled = _cfg['enabled'] as bool? ?? false;
      _smtpHostCtrl.text = _cfg['smtp_host'] as String? ?? '';
      _smtpPortCtrl.text = (_cfg['smtp_port'] ?? 587).toString();
      _smtpUserCtrl.text = _cfg['smtp_user'] as String? ?? '';
      _fromCtrl.text = _cfg['from_addr'] as String? ?? '';
      _alertToCtrl.text = _cfg['alert_to'] as String? ?? '';
      _smtpTls = _cfg['smtp_tls'] as bool? ?? true;
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _api.updateEmailConfig({
        'enabled': _enabled,
        'provider': 'smtp',
        'smtp_host': _smtpHostCtrl.text,
        'smtp_port': int.tryParse(_smtpPortCtrl.text) ?? 587,
        'smtp_user': _smtpUserCtrl.text,
        'smtp_pass': _smtpPassCtrl.text,
        'smtp_tls': _smtpTls,
        'from_addr': _fromCtrl.text,
        'alert_to': _alertToCtrl.text,
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    try {
      await _api.testEmail();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Test email sent!')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Email Alerts Config'),
        actions: [
          if (!_loading)
            TextButton(onPressed: _test, child: const Text('Send Test')),
          if (!_loading)
            TextButton(onPressed: _saving ? null : _save, child: const Text('Save')),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                SwitchListTile(
                  title: const Text('Enable Email Alerts'),
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
                if (_enabled) ...[
                  const SizedBox(height: 8),
                  TextField(controller: _smtpHostCtrl,
                    decoration: const InputDecoration(labelText: 'SMTP Host', hintText: 'smtp.gmail.com')),
                  const SizedBox(height: 8),
                  TextField(controller: _smtpPortCtrl, keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'SMTP Port', hintText: '587')),
                  const SizedBox(height: 8),
                  TextField(controller: _smtpUserCtrl,
                    decoration: const InputDecoration(labelText: 'SMTP Username')),
                  const SizedBox(height: 8),
                  TextField(controller: _smtpPassCtrl, obscureText: true,
                    decoration: const InputDecoration(labelText: 'SMTP Password (leave blank to keep)')),
                  SwitchListTile(
                    title: const Text('Use TLS / STARTTLS'),
                    value: _smtpTls,
                    onChanged: (v) => setState(() => _smtpTls = v),
                  ),
                  const SizedBox(height: 8),
                  TextField(controller: _fromCtrl,
                    decoration: const InputDecoration(labelText: 'From Address')),
                  const SizedBox(height: 8),
                  TextField(controller: _alertToCtrl,
                    decoration: const InputDecoration(labelText: 'Alert To Address')),
                ],
              ]),
            ),
    );
  }

  @override
  void dispose() {
    for (final c in [_smtpHostCtrl, _smtpPortCtrl, _smtpUserCtrl, _smtpPassCtrl, _fromCtrl, _alertToCtrl]) {
      c.dispose();
    }
    super.dispose();
  }
}
