import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models/vault_config.dart';
import '../models/user_info.dart';

/// Manages the list of configured vaults ("servers") and tracks which one is
/// currently active.  All data is persisted in FlutterSecureStorage.
///
/// Usage:
///   await VaultManager.instance.init();   // once at startup
///   VaultManager.instance.active         // current VaultConfig
///   VaultManager.instance.getToken()     // JWT for the active vault
class VaultManager extends ChangeNotifier {
  VaultManager._();
  static final VaultManager instance = VaultManager._();

  static const _storage = FlutterSecureStorage();
  static const _keyVaultList = 'vault_list_v2';
  static const _keyActiveId = 'vault_active_id';

  List<VaultConfig> _vaults = [];
  String? _activeId;

  List<VaultConfig> get vaults => List.unmodifiable(_vaults);

  // ── Active vault ───────────────────────────────────────────────────────────

  VaultConfig? get active =>
      _vaults.isEmpty ? null : (_vaults.firstWhere(
        (v) => v.id == _activeId,
        orElse: () => _vaults.first,
      ));

  Future<void> setActive(VaultConfig v) async {
    _activeId = v.id;
    await _storage.write(key: _keyActiveId, value: v.id);
    notifyListeners();
  }

  // ── CRUD ──────────────────────────────────────────────────────────────────

  Future<VaultConfig> addVault(VaultConfig v) async {
    _vaults.add(v);
    if (_vaults.length == 1) _activeId = v.id;
    await _persist();
    notifyListeners();
    return v;
  }

  Future<void> updateVault(VaultConfig v) async {
    final idx = _vaults.indexWhere((x) => x.id == v.id);
    if (idx >= 0) _vaults[idx] = v;
    await _persist();
    notifyListeners();
  }

  Future<void> deleteVault(VaultConfig v) async {
    await _deleteToken(v.id);
    _vaults.removeWhere((x) => x.id == v.id);
    if (_activeId == v.id) _activeId = _vaults.isEmpty ? null : _vaults.first.id;
    await _persist();
    notifyListeners();
  }

  // ── Token helpers (per vault) ─────────────────────────────────────────────

  Future<String?> getToken() async {
    final id = active?.id;
    if (id == null) return null;
    return _storage.read(key: _tokenKey(id));
  }

  Future<void> setToken(String token) async {
    final id = active?.id;
    if (id == null) return;
    await _storage.write(key: _tokenKey(id), value: token);
  }

  Future<void> clearToken() async {
    final id = active?.id;
    if (id == null) return;
    await _deleteToken(id);
    _userInfo = null;
    notifyListeners();
  }

  Future<void> _deleteToken(String vaultId) =>
      _storage.delete(key: _tokenKey(vaultId));

  String _tokenKey(String vaultId) => 'vault_token_$vaultId';

  // ── Per-vault user info ────────────────────────────────────────────────────

  UserInfo? _userInfo;
  UserInfo? get currentUser => _userInfo;
  bool get isAdmin => _userInfo?.isAdmin ?? false;
  String get username => _userInfo?.username ?? 'admin';

  Future<void> setUserInfo(UserInfo info) async {
    _userInfo = info;
    final id = active?.id;
    if (id == null) return;
    await _storage.write(key: 'vault_username_$id', value: info.username);
    await _storage.write(key: 'vault_is_admin_$id', value: info.isAdmin ? '1' : '0');
    notifyListeners();
  }

  Future<void> _loadUserInfo() async {
    final id = active?.id;
    if (id == null) return;
    final username = await _storage.read(key: 'vault_username_$id') ?? 'admin';
    final isAdminStr = await _storage.read(key: 'vault_is_admin_$id') ?? '0';
    _userInfo = UserInfo(
      username: username,
      isAdmin: isAdminStr == '1',
      perms: UserPermissions.adminAll(),
    );
  }

  // ── Convenience getters ────────────────────────────────────────────────────

  /// Primary API base URL for auth / TOTP / safe requests.
  String getApiBase() =>
      active?.apiBase ?? 'http://100.64.0.1:8443';

  /// API base URL for backup requests (may differ for LAN speed).
  String getBackupApiBase() =>
      active?.effectiveBackupBase ?? getApiBase();

  /// Returns an [http.Client] configured for the active vault.
  /// Supports HTTPS with self-signed certificates when the vault has
  /// [VaultConfig.allowSelfSigned] = true.
  http.Client makeClient() {
    final vault = active;
    if (vault != null && vault.allowSelfSigned) {
      // Only available on native platforms (not web).
      if (!kIsWeb) {
        try {
          final inner = HttpClient()
            ..badCertificateCallback = (_, __, ___) => true;
          return IOClient(inner);
        } catch (_) {}
      }
    }
    return http.Client();
  }

  // ── Init / persistence ─────────────────────────────────────────────────────

  bool _initialised = false;

  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;

    final listJson = await _storage.read(key: _keyVaultList);
    if (listJson != null) {
      try {
        final list = jsonDecode(listJson) as List<dynamic>;
        _vaults = list
            .map((j) => VaultConfig.fromJson(j as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _vaults = [];
      }
    }

    _activeId = await _storage.read(key: _keyActiveId);

    // ─── Migration: if zero vaults but an old single-vault config exists,
    //     import it automatically so the user doesn't have to re-enter anything.
    if (_vaults.isEmpty) {
      final oldApiBase = await _storage.read(key: 'api_base_url');
      final oldToken   = await _storage.read(key: 'auth_token');
      if (oldApiBase != null) {
        final migrated = VaultConfig(
          name: 'My Vault',
          apiBase: oldApiBase,
        );
        _vaults.add(migrated);
        _activeId = migrated.id;
        await _persist();
        if (oldToken != null) {
          await _storage.write(key: _tokenKey(migrated.id), value: oldToken);
        }
      }
    }

    // Ensure _activeId points to a real vault.
    if (_activeId == null ||
        !_vaults.any((v) => v.id == _activeId)) {
      _activeId = _vaults.isEmpty ? null : _vaults.first.id;
    }

    await _loadUserInfo();
  }

  Future<void> _persist() async {
    await _storage.write(
      key: _keyVaultList,
      value: jsonEncode(_vaults.map((v) => v.toJson()).toList()),
    );
    if (_activeId != null) {
      await _storage.write(key: _keyActiveId, value: _activeId!);
    }
  }
}
