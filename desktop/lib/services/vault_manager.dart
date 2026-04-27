import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/vault_config.dart';
import '../models/user_info.dart';

/// Manages multiple vault configurations for the desktop client.
/// Uses SharedPreferences for persistence (no secure storage on desktop).
class VaultManager extends ChangeNotifier {
  VaultManager._();
  static final instance = VaultManager._();

  static const _keyVaultList = 'vault_list_v2';
  static const _keyActiveId = 'vault_active_id';

  // Legacy migration keys
  static const _legacyApiBase = 'api_base_url';
  static const _legacyToken = 'auth_token';

  List<VaultConfig> _vaults = [];
  String? _activeId;
  SharedPreferences? _prefs;

  List<VaultConfig> get vaults => List.unmodifiable(_vaults);
  VaultConfig? get active =>
      _vaults.isEmpty ? null : _vaults.firstWhere(
        (v) => v.id == _activeId,
        orElse: () => _vaults.first,
      );

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _load();
    if (_vaults.isEmpty) await _migrate();
    _loadUserInfo();
  }

  Future<void> _load() async {
    final raw = _prefs!.getString(_keyVaultList);
    if (raw != null) {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      _vaults = list.map(VaultConfig.fromJson).toList();
    }
    _activeId = _prefs!.getString(_keyActiveId);
  }

  Future<void> _migrate() async {
    final legacyBase = _prefs!.getString(_legacyApiBase);
    if (legacyBase == null || legacyBase.isEmpty) return;
    final v = VaultConfig(
      id: const Uuid().v4(),
      name: 'My Vault',
      apiBase: legacyBase,
    );
    _vaults = [v];
    _activeId = v.id;
    await _persist();
    // Leave legacy token in place so the desktop still opens without re-login
  }

  Future<void> _persist() async {
    await _prefs!.setString(
        _keyVaultList, jsonEncode(_vaults.map((v) => v.toJson()).toList()));
    if (_activeId != null) {
      await _prefs!.setString(_keyActiveId, _activeId!);
    }
    notifyListeners();
  }

  // ── CRUD ──────────────────────────────────────────────────────────────────

  Future<VaultConfig> addVault(VaultConfig v) async {
    _vaults = [..._vaults, v];
    _activeId ??= v.id;
    await _persist();
    return v;
  }

  Future<void> updateVault(VaultConfig v) async {
    _vaults = [for (final e in _vaults) e.id == v.id ? v : e];
    await _persist();
  }

  Future<void> deleteVault(String id) async {
    _vaults = _vaults.where((v) => v.id != id).toList();
    if (_activeId == id) _activeId = _vaults.isEmpty ? null : _vaults.first.id;
    await _persist();
  }

  Future<void> setActive(String id) async {
    _activeId = id;
    await _persist();
  }

  // ── Token helpers (per-vault, stored in prefs keyed by vault id) ──────────

  String _tokenKey(String id) => 'vault_token_$id';

  Future<String?> getToken() async {
    final v = active;
    if (v == null) return null;
    // Try per-vault key first, fall back to legacy key for migration
    return _prefs!.getString(_tokenKey(v.id)) ??
        _prefs!.getString(_legacyToken);
  }

  Future<void> setToken(String token) async {
    final v = active;
    if (v == null) return;
    await _prefs!.setString(_tokenKey(v.id), token);
  }

  Future<void> clearToken() async {
    final v = active;
    if (v == null) return;
    await _prefs!.remove(_tokenKey(v.id));
    _userInfo = null;
    notifyListeners();
  }

  // ── Per-vault user info ────────────────────────────────────────────────────

  UserInfo? _userInfo;
  UserInfo? get currentUser => _userInfo;
  bool get isAdmin => _userInfo?.isAdmin ?? false;
  String get username => _userInfo?.username ?? 'admin';

  Future<void> setUserInfo(UserInfo info) async {
    _userInfo = info;
    final v = active;
    if (v == null) return;
    await _prefs!.setString('vault_username_${v.id}', info.username);
    await _prefs!.setBool('vault_is_admin_${v.id}', info.isAdmin);
    notifyListeners();
  }

  void _loadUserInfo() {
    final v = active;
    if (v == null) return;
    final uname = _prefs!.getString('vault_username_${v.id}') ?? 'admin';
    final admin = _prefs!.getBool('vault_is_admin_${v.id}') ?? false;
    _userInfo = UserInfo(
      username: uname,
      isAdmin: admin,
      perms: UserPermissions.adminAll(),
    );
  }

  // ── URL helpers ───────────────────────────────────────────────────────────

  String getApiBase() => active?.apiBase ?? 'http://localhost:8443';
  String getBackupApiBase() => active?.effectiveBackupBase ?? getApiBase();

  // ── HTTP client (self-signed cert bypass per vault) ───────────────────────

  http.Client makeClient() {
    if (active?.allowSelfSigned == true) {
      final ctx = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
      return IOClient(ctx);
    }
    return http.Client();
  }
}
