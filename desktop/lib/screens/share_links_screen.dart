import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';

class ShareLinksScreen extends StatefulWidget {
  const ShareLinksScreen({super.key});
  @override
  State<ShareLinksScreen> createState() => _ShareLinksScreenState();
}

class _ShareLinksScreenState extends State<ShareLinksScreen> {
  final _api = ApiService();
  List<Map<String, dynamic>> _links = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try { _links = await _api.getShareLinks(); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
    finally { setState(() => _loading = false); }
  }

  Future<void> _delete(int id) async {
    await _api.deleteShareLink(id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Share Links'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _links.isEmpty
              ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.link_off, size: 64, color: Colors.grey),
                  SizedBox(height: 8),
                  Text('No active share links.'),
                  Text('Create one from a record\'s detail screen.', style: TextStyle(color: Colors.grey)),
                ]))
              : ListView.builder(
                  itemCount: _links.length,
                  itemBuilder: (ctx, i) {
                    final l = _links[i];
                    final token = l['token'] as String? ?? '';
                    final oneTime = l['one_time'] == true || l['one_time'] == 1;
                    final used = l['used_at'] != null && l['used_at'] != 0;
                    return ListTile(
                      leading: Icon(Icons.link, color: used ? Colors.grey : Colors.blue),
                      title: Text('Record #${l['record_id']}  ${oneTime ? "(one-time)" : ""}'),
                      subtitle: Text('${token.substring(0, 12)}…  ${used ? "Used" : "Active"}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (!used)
                          IconButton(
                            icon: const Icon(Icons.copy),
                            tooltip: 'Copy token',
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: token));
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Token copied')));
                            },
                          ),
                        IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () => _delete(l['id'] as int),
                        ),
                      ]),
                    );
                  },
                ),
    );
  }
}
