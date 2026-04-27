// Thin shim — all real logic lives in VaultManager.
// Kept for backward-compatibility with callers that haven't been migrated yet.
import '../services/vault_manager.dart';

class AppConfig {
  static Future<String> getApiBase() async =>
      VaultManager.instance.getApiBase();

  static Future<void> setApiBase(String url) async {
    final v = VaultManager.instance.active;
    if (v == null) return;
    final clean = url.trimRight().replaceAll(RegExp(r'/$'), '');
    await VaultManager.instance.updateVault(v.copyWith(apiBase: clean));
  }

  // Client-secret is no longer used by vault-aware code, kept as no-op.
  static Future<String> getClientSecret() async => '';
  static Future<void> setClientSecret(String s) async {}

  static Future<String?> getToken() async => VaultManager.instance.getToken();

  static Future<void> setToken(String t) async =>
      VaultManager.instance.setToken(t);

  static Future<void> clearToken() async => VaultManager.instance.clearToken();
}
