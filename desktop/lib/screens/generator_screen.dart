import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';

class GeneratorScreen extends StatefulWidget {
  const GeneratorScreen({super.key});
  @override
  State<GeneratorScreen> createState() => _GeneratorScreenState();
}

class _GeneratorScreenState extends State<GeneratorScreen> {
  final _api = ApiService();
  String _password = '';
  int _length = 16;
  bool _uppercase = true, _digits = true, _symbols = true, _noAmbiguous = false;
  int _strength = 0;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    setState(() => _loading = true);
    try {
      final r = await _api.generatePassword(
        length: _length, uppercase: _uppercase,
        digits: _digits, symbols: _symbols, noAmbiguous: _noAmbiguous,
      );
      setState(() {
        _password = r['password'] as String? ?? '';
        _strength = r['strength'] as int? ?? 0;
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  Color get _strengthColor {
    if (_strength >= 80) return Colors.green;
    if (_strength >= 50) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Password Generator')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                SelectableText(
                  _password.isEmpty ? '...' : _password,
                  style: const TextStyle(fontSize: 20, fontFamily: 'monospace'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: _strength / 100,
                  color: _strengthColor,
                  backgroundColor: Colors.grey[300],
                ),
                Text('Strength: $_strength/100', style: TextStyle(color: _strengthColor)),
                const SizedBox(height: 8),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  IconButton(
                    icon: const Icon(Icons.copy),
                    tooltip: 'Copy',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _password));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Copied!')));
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Generate',
                    onPressed: _loading ? null : _generate,
                  ),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                Row(children: [
                  const Text('Length: '),
                  Expanded(
                    child: Slider(
                      value: _length.toDouble(),
                      min: 8, max: 64, divisions: 56,
                      label: '$_length',
                      onChanged: (v) => setState(() => _length = v.round()),
                      onChangeEnd: (_) => _generate(),
                    ),
                  ),
                  Text('$_length'),
                ]),
                CheckboxListTile(title: const Text('Uppercase (A-Z)'), value: _uppercase,
                  onChanged: (v) { setState(() => _uppercase = v!); _generate(); }),
                CheckboxListTile(title: const Text('Digits (0-9)'), value: _digits,
                  onChanged: (v) { setState(() => _digits = v!); _generate(); }),
                CheckboxListTile(title: const Text('Symbols (!@#...)'), value: _symbols,
                  onChanged: (v) { setState(() => _symbols = v!); _generate(); }),
                CheckboxListTile(title: const Text('Avoid ambiguous (0Ol1I)'), value: _noAmbiguous,
                  onChanged: (v) { setState(() => _noAmbiguous = v!); _generate(); }),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
