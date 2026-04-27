import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final _api = ApiService();
  List<TotpEntry> _entries = [];
  bool _loading = true;
  String? _error;
  Timer? _timer;
  Timer? _refreshTimer;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _silentRefresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final entries = await _api.getTotpEntries();
      setState(() { _entries = entries; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _silentRefresh() async {
    if (!mounted) return;
    try {
      final entries = await _api.getTotpEntries();
      if (mounted) setState(() => _entries = entries);
    } catch (_) {}
  }

  List<TotpEntry> get _filtered {
    if (_search.isEmpty) return _entries;
    final q = _search.toLowerCase();
    return _entries.where((e) =>
        e.name.toLowerCase().contains(q) ||
        e.issuer.toLowerCase().contains(q)).toList();
  }

  void _copyCode(TotpEntry e) {
    final code = TotpCalculator.generate(
      secret: e.secret,
      duration: e.duration,
      length: e.length,
      hashAlgo: e.hashAlgo,
    );
    Clipboard.setData(ClipboardData(text: code));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied ${e.name} code'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        width: 280,
      ),
    );
  }

  Future<void> _addEntry() async {
    final result = await showDialog<TotpEntry>(
      context: context,
      builder: (_) => const AddTotpDialog(),
    );
    if (result == null) return;
    try {
      final created = await _api.createTotp(result);
      setState(() => _entries.add(created));
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  Future<void> _editEntry(TotpEntry entry) async {
    final result = await showDialog<TotpEntry>(
      context: context,
      builder: (_) => AddTotpDialog(entry: entry),
    );
    if (result == null) return;
    try {
      final updated = await _api.updateTotp(result);
      setState(() {
        final i = _entries.indexWhere((e) => e.id == updated.id);
        if (i >= 0) _entries[i] = updated;
      });
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  Future<void> _deleteEntry(TotpEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete ${entry.name}?'),
        content: const Text('This action cannot be undone.'),
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
    if (ok != true) return;
    try {
      await _api.deleteTotp(entry.id!);
      setState(() => _entries.removeWhere((e) => e.id == entry.id));
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final body = _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.error_outline, color: cs.error, size: 48),
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: cs.error)),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _load, child: const Text('Retry')),
                  ]),
                )
              : _filtered.isEmpty
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.access_time_filled, size: 72, color: cs.primaryContainer),
                        const SizedBox(height: 20),
                        Text(
                          _search.isEmpty
                              ? 'No authenticator entries yet'
                              : 'No entries match "$_search"',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        if (_search.isEmpty) ...[
                          Text(
                            'Add a TOTP account using the button above,\nor import an Accounts.json in Settings.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: cs.onSurfaceVariant),
                          ),
                          const SizedBox(height: 24),
                          FilledButton.icon(
                            onPressed: _addEntry,
                            icon: const Icon(Icons.add),
                            label: const Text('Add Entry'),
                            style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14)),
                          ),
                        ],
                      ]),
                    )
                  : Padding(
                      padding: const EdgeInsets.all(16),
                      child: LayoutBuilder(
                        builder: (ctx, constraints) {
                          final cols = (constraints.maxWidth / 280).floor().clamp(1, 6);
                          return GridView.builder(
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: cols,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childAspectRatio: 1.6,
                            ),
                            itemCount: _filtered.length,
                            itemBuilder: (_, i) => _TotpCard(
                              entry: _filtered[i],
                              onCopy: () => _copyCode(_filtered[i]),
                              onEdit: () => _editEntry(_filtered[i]),
                              onDelete: () => _deleteEntry(_filtered[i]),
                            ),
                          );
                        },
                      ),
                    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          elevation: 2,
          color: cs.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              Text('Authenticator',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              SizedBox(
                width: 280,
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Search...',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    filled: true,
                    fillColor: cs.surfaceContainerHighest,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _addEntry,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
              ),
            ]),
          ),
        ),
        Expanded(child: body),
      ],
    );
  }
}

class _TotpCard extends StatefulWidget {
  final TotpEntry entry;
  final VoidCallback onCopy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _TotpCard({
    required this.entry,
    required this.onCopy,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_TotpCard> createState() => _TotpCardState();
}

class _TotpCardState extends State<_TotpCard> {
  Timer? _t;
  String _code = '';
  int _secs = 0;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() { _t?.cancel(); super.dispose(); }

  void _refresh() {
    if (!mounted) return;
    setState(() {
      _code = TotpCalculator.generate(
        secret: widget.entry.secret,
        duration: widget.entry.duration,
        length: widget.entry.length,
        hashAlgo: widget.entry.hashAlgo,
      );
      _secs = TotpCalculator.secondsRemaining(duration: widget.entry.duration);
      _progress = TotpCalculator.progress(duration: widget.entry.duration);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final urgent = _secs <= 5;
    final codeColor = urgent ? cs.error : cs.primary;

    return Card(
      color: cs.surfaceContainerHigh,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: widget.onCopy,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(widget.entry.issuer,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: cs.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    Text(widget.entry.name,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ]),
                ),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert, size: 18, color: cs.onSurfaceVariant),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: Colors.red))),
                  ],
                  onSelected: (v) {
                    if (v == 'edit') widget.onEdit();
                    if (v == 'delete') widget.onDelete();
                  },
                ),
              ]),
              const Spacer(),
              Row(children: [
                Text(
                  _code,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontFamily: 'monospace',
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 4,
                      color: codeColor),
                ),
                const Spacer(),
                Stack(alignment: Alignment.center, children: [
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                      value: 1 - _progress,
                      color: codeColor,
                      backgroundColor: cs.outlineVariant.withOpacity(0.3),
                      strokeWidth: 3,
                    ),
                  ),
                  Text('$_secs',
                      style: TextStyle(fontSize: 10, color: codeColor, fontWeight: FontWeight.bold)),
                ]),
              ]),
              const SizedBox(height: 4),
              Text('Tap to copy',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant.withOpacity(0.6))),
            ],
          ),
        ),
      ),
    );
  }
}
