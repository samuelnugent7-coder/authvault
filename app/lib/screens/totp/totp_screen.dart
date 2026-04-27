import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/totp_entry.dart';
import '../../services/api_service.dart';
import '../../services/totp_calculator.dart';
import 'add_totp_screen.dart';

class TotpScreen extends StatefulWidget {
  const TotpScreen({super.key});
  @override
  State<TotpScreen> createState() => _TotpScreenState();
}

class _TotpScreenState extends State<TotpScreen> {
  List<TotpEntry> _entries = [];
  bool _loading = true;
  String? _error;
  Timer? _ticker;
  Timer? _refreshTimer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
    // 1-second tick for the countdown progress bars.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _now = DateTime.now());
    });
    // Silently re-fetch entries every 30 seconds to pick up changes from other devices.
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _silentRefresh());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final api = context.read<ApiService>();
      final entries = await api.getTotpEntries();
      setState(() { _entries = entries; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _silentRefresh() async {
    if (!mounted) return;
    try {
      final entries = await context.read<ApiService>().getTotpEntries();
      if (mounted) setState(() => _entries = entries);
    } catch (_) {}
  }

  Future<void> _delete(TotpEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Entry'),
        content: Text('Delete "${e.name}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await context.read<ApiService>().deleteTotp(e.id!);
      _load();
    }
  }

  Future<void> _openAdd() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const AddTotpScreen()),
    );
    if (result == true) _load();
  }

  Future<void> _openEdit(TotpEntry e) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AddTotpScreen(existing: e)),
    );
    if (result == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 56, color: cs.error),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center,
                  style: TextStyle(color: cs.error)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    } else if (_entries.isEmpty) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.access_time_filled, size: 72, color: cs.primaryContainer),
              const SizedBox(height: 24),
              Text('No authenticator entries yet',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                'Add a TOTP account to get started.\nYou can scan a QR code or enter a secret manually.',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: _openAdd,
                icon: const Icon(Icons.add),
                label: const Text('Add Account'),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 14)),
              ),
            ],
          ),
        ),
      );
    } else {
      body = Stack(children: [
        ListView.builder(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 80),
          itemCount: _entries.length,
          itemBuilder: (ctx, i) => _TotpTile(
            entry: _entries[i],
            now: _now,
            onEdit: () => _openEdit(_entries[i]),
            onDelete: () => _delete(_entries[i]),
          ),
        ),
        Positioned(
          bottom: 16,
          right: 16,
          child: FloatingActionButton(
            onPressed: _openAdd,
            tooltip: 'Add TOTP',
            child: const Icon(Icons.add),
          ),
        ),
      ]);
    }
    return body;
  }
}

class _TotpTile extends StatelessWidget {
  final TotpEntry entry;
  final DateTime now;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _TotpTile({
    required this.entry,
    required this.now,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final code = _safeGenerate();
    final remaining = TotpCalculator.secondsRemaining(duration: entry.duration, now: now);
    final progress = TotpCalculator.progress(duration: entry.duration, now: now);
    final urgent = remaining <= 5;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: urgent ? Colors.red.withOpacity(0.2) : Colors.blue.withOpacity(0.2),
          child: Text(
            remaining.toString(),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: urgent ? Colors.redAccent : Colors.blueAccent,
            ),
          ),
        ),
        title: Text(
          _formatCode(code),
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontFamily: 'monospace',
                letterSpacing: 4,
                color: urgent ? Colors.redAccent : null,
              ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(entry.issuer.isNotEmpty ? '${entry.issuer}  •  ${entry.name}' : entry.name),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: 1.0 - progress,
                backgroundColor: Colors.grey.withOpacity(0.3),
                color: urgent ? Colors.redAccent : Colors.blueAccent,
                minHeight: 4,
              ),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.copy, size: 20),
              tooltip: 'Copy',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied!'), duration: Duration(seconds: 1)),
                );
              },
            ),
            PopupMenuButton<String>(
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
              onSelected: (v) {
                if (v == 'edit') onEdit();
                if (v == 'delete') onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }

  String _safeGenerate() {
    try {
      return TotpCalculator.generate(
        secret: entry.secret,
        duration: entry.duration,
        length: entry.length,
        hashAlgo: entry.hashAlgo,
        now: now,
      );
    } catch (_) {
      return '------';
    }
  }

  String _formatCode(String code) {
    if (code.length == 6) return '${code.substring(0, 3)} ${code.substring(3)}';
    return code;
  }
}
