import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../services/sync_service.dart';
import '../services/vault_manager.dart';
import 'main_screen.dart';
import 'vault_manage_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _unameController = TextEditingController(text: 'admin');
  final _pwController = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _unameController.dispose();
    _pwController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final uname = _unameController.text.trim().toLowerCase();
    final pw = _pwController.text.trim();
    if (uname.isEmpty) {
      setState(() => _error = 'Enter your username');
      return;
    }
    if (pw.isEmpty) {
      setState(() => _error = 'Enter your password');
      return;
    }
    if (VaultManager.instance.active == null) {
      setState(() => _error = 'Add a vault first (tap the server chip below)');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final api = context.read<ApiService>();
      await api.login(uname, pw);
      await SyncService.instance.init();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainScreen()),
      );
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Cannot reach server: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _goManageVaults() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const VaultManageScreen()),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: ListenableBuilder(
                listenable: VaultManager.instance,
                builder: (_, __) {
                  final vault = VaultManager.instance.active;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.security, size: 72, color: Color(0xFF1A73E8)),
                      const SizedBox(height: 16),
                      Text('AuthVault',
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text('TOTP & Password Safe',
                          style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 28),

                      // Vault selector chip
                      InkWell(
                        onTap: _goManageVaults,
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: vault != null
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.orange),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                vault != null ? Icons.dns_outlined : Icons.add_circle_outline,
                                size: 16,
                                color: vault != null
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.orange,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                vault != null ? vault.name : 'Tap to add a vault',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: vault != null
                                      ? Theme.of(context).colorScheme.primary
                                      : Colors.orange,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(Icons.expand_more,
                                  size: 16,
                                  color: vault != null
                                      ? Theme.of(context).colorScheme.primary
                                      : Colors.orange),
                            ],
                          ),
                        ),
                      ),
                      if (vault != null) ...[
                        const SizedBox(height: 4),
                        Text(vault.apiBase,
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey, fontFamily: 'monospace')),
                      ],

                      const SizedBox(height: 28),
                      TextField(
                        controller: _unameController,
                        enabled: vault != null,
                        textInputAction: TextInputAction.next,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Username',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _pwController,
                        obscureText: _obscure,
                        enabled: vault != null,
                        decoration: InputDecoration(
                          labelText: 'Master Password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        onSubmitted: (_) => _login(),
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
                          onPressed: (_loading || vault == null) ? null : _login,
                          icon: _loading
                              ? const SizedBox(width: 18, height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.login),
                          label: Text(_loading ? 'Connecting...' : 'Unlock'),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
