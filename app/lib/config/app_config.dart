import '../services/vault_manager.dart';

/// Thin compatibility shim — all calls delegate to [VaultManager.instance].
/// New code should use [VaultManager] directly.
class AppConfig {
  static Future<String> getApiBase() async =>
      VaultManager.instance.getApiBase();

  /// Updating the API base updates the *active vault*'s apiBase in-place.
  static Future<void> setApiBase(String url) async {
    final v = VaultManager.instance.active;
    if (v == null) return;
    final clean = url.trimRight().replaceAll(RegExp(r'/$'), '');
    await VaultManager.instance.updateVault(v.copyWith(apiBase: clean));
  }

  static Future<String?> getToken() => VaultManager.instance.getToken();

  static Future<void> setToken(String t) => VaultManager.instance.setToken(t);

  static Future<void> clearToken() => VaultManager.instance.clearToken();
}
