import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/totp_entry.dart';
import '../models/safe_node.dart';
import '../models/user_info.dart';
import 'cache_service.dart';
import 'sync_service.dart';
import 'vault_manager.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  const ApiException(this.statusCode, this.message);
  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiService {
  static int _tempIdCounter = 0;
  static int get _nextTempId => --_tempIdCounter;

  // ---- Auth ----

  /// Logs in with username + password (username defaults to "admin").
  /// Returns a [UserInfo] with the token embedded in [VaultManager].
  Future<UserInfo> login(String username, String password) async {
    final res = await _post(
      '/api/v1/auth/login',
      {'username': username.trim().isEmpty ? 'admin' : username.trim(), 'password': password},
      auth: false,
    );
    final token = res['token'] as String;
    CacheService.instance.setKeyFromToken(token);
    await VaultManager.instance.setToken(token);
    final info = UserInfo.fromJson(res);
    await VaultManager.instance.setUserInfo(info);
    await SyncService.instance.init();
    return info;
  }

  Future<void> logout() async {
    final token = await AppConfig.getToken();
    if (token == null) return;
    try { await _post('/api/v1/auth/logout', {}); } catch (_) {}
    await AppConfig.clearToken();
    await CacheService.instance.clearAll();
  }

  Future<UserInfo?> getMe() async {
    try {
      final res = await _get('/api/v1/auth/me');
      return UserInfo.fromJson(res);
    } catch (_) {
      return null;
    }
  }

  // ---- Admin ----

  Future<List<Map<String, dynamic>>> adminListUsers() async =>
      await _getList('/api/v1/admin/users');

  Future<Map<String, dynamic>> adminCreateUser(
          String username, String password, {bool isAdmin = false}) async =>
      await _post('/api/v1/admin/users',
          {'username': username, 'password': password, 'is_admin': isAdmin});

  Future<Map<String, dynamic>> adminUpdateUser(
          int id, {String password = '', required bool isAdmin}) async =>
      await _put('/api/v1/admin/users/$id',
          {'password': password, 'is_admin': isAdmin});

  Future<void> adminDeleteUser(int id) async =>
      await _delete('/api/v1/admin/users/$id');

  Future<Map<String, dynamic>> adminGetPermissions(int id) async =>
      await _get('/api/v1/admin/users/$id/permissions');

  Future<Map<String, dynamic>> adminSetPermissions(
          int id, Map<String, dynamic> perms) async =>
      await _put('/api/v1/admin/users/$id/permissions', perms);

  Future<bool> isServerUnlocked() async {
    try {
      final base = VaultManager.instance.getApiBase();
      final client = VaultManager.instance.makeClient();
      try {
        final res = await client
            .get(Uri.parse('$base/api/v1/auth/status'))
            .timeout(const Duration(seconds: 5));
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        return body['unlocked'] as bool? ?? false;
      } finally {
        client.close();
      }
    } catch (_) {
      return false;
    }
  }

  // ---- TOTP ----

  Future<List<TotpEntry>> getTotpEntries() async {
    try {
      final data = await _getList('/api/v1/totp');
      await CacheService.instance.write('totp.bin', data);
      return data.map((j) => TotpEntry.fromJson(j)).toList();
    } catch (_) {
      final cached = await CacheService.instance.read('totp.bin');
      if (cached is List) {
        return cached.cast<Map<String, dynamic>>().map(TotpEntry.fromJson).toList();
      }
      rethrow;
    }
  }

  Future<TotpEntry> createTotp(TotpEntry e) async {
    final tempId = _nextTempId;
    final optimistic = TotpEntry(
      id: tempId, name: e.name, issuer: e.issuer,
      secret: e.secret, duration: e.duration, length: e.length, hashAlgo: e.hashAlgo,
    );
    await _updateTotpInCache(optimistic, insert: true);
    try {
      final res = await _post('/api/v1/totp', e.toJson());
      final created = TotpEntry.fromJson(res);
      await _replaceTotpIdInCache(tempId, created);
      return created;
    } catch (_) {
      await SyncService.instance.enqueue(SyncService.instance.makeCreateTotp(e, tempId));
      return optimistic;
    }
  }

  Future<TotpEntry> updateTotp(TotpEntry e) async {
    await _updateTotpInCache(e);
    try {
      final res = await _put('/api/v1/totp/${e.id}', e.toJson());
      if (res != null) return TotpEntry.fromJson(res as Map<String, dynamic>);
      return e;
    } catch (_) {
      await SyncService.instance.enqueue(SyncService.instance.makeUpdateTotp(e));
      return e;
    }
  }

  Future<void> deleteTotp(int id) async {
    await _deleteTotpFromCache(id);
    try {
      await _delete('/api/v1/totp/$id');
    } catch (_) {
      await SyncService.instance.enqueue(SyncService.instance.makeDeleteTotp(id));
    }
  }

  Future<Map<String, dynamic>> importTotp(String jsonStr) async {
    final data = jsonDecode(jsonStr) as List<dynamic>;
    return await _postRaw('/api/v1/totp/import', jsonEncode(data));
  }

  Future<String> exportTotp() async {
    final list = await _getList('/api/v1/totp/export');
    return const JsonEncoder.withIndent('  ').convert(list);
  }

  // ---- Safe ----

  Future<List<SafeFolder>> getSafe() async {
    try {
      final data = await _getList('/api/v1/safe');
      await CacheService.instance.write('safe.bin', data);
      return data.map((j) => SafeFolder.fromJson(j)).toList();
    } catch (_) {
      final cached = await CacheService.instance.read('safe.bin');
      if (cached is List) {
        return cached.cast<Map<String, dynamic>>().map(SafeFolder.fromJson).toList();
      }
      rethrow;
    }
  }

  Future<int> createFolder(String name, {int? parentId}) async {
    final tempId = _nextTempId;
    final optimistic = SafeFolder(id: tempId, name: name, records: []);
    await _insertFolderInCache(optimistic);
    try {
      final res = await _post('/api/v1/safe/folders', {
        'name': name,
        if (parentId != null) 'parent_id': parentId,
      });
      final realId = res['id'] as int;
      await _replaceFolderIdInCache(tempId, realId);
      return realId;
    } catch (_) {
      await SyncService.instance.enqueue(SyncService.instance.makeCreateFolder(name, tempId));
      return tempId;
    }
  }

  Future<void> updateFolder(int id, String name) async {
    await _updateFolderInCache(id, name);
    try {
      await _put('/api/v1/safe/folders/$id', {'name': name});
    } catch (_) {
      await SyncService.instance.enqueue(SyncService.instance.makeUpdateFolder(id, name));
    }
  }

  Future<void> deleteFolder(int id) async {
    await _deleteFolderFromCache(id);
    try {
      await _delete('/api/v1/safe/folders/$id');
    } catch (_) {
      await SyncService.instance.enqueue(SyncService.instance.makeDeleteFolder(id));
    }
  }

  Future<SafeRecord> createRecord(SafeRecord r) async {
    final tempId = _nextTempId;
    final optimistic = SafeRecord(
      id: tempId, folderId: r.folderId, name: r.name,
      login: r.login, password: r.password,
    );
    await _insertRecordInCache(optimistic);
    try {
      final res = await _post('/api/v1/safe/records', r.toJson());
      final created = SafeRecord.fromJson(res);
      await _replaceRecordIdInCache(tempId, created);
      return created;
    } catch (_) {
      await SyncService.instance.enqueue(SyncService.instance.makeCreateRecord(r, tempId));
      return optimistic;
    }
  }

  Future<SafeRecord> updateRecord(SafeRecord r) async {
    await _updateRecordInCache(r);
    try {
      final res = await _put('/api/v1/safe/records/${r.id}', r.toJson());
      if (res != null) return SafeRecord.fromJson(res as Map<String, dynamic>);
      return r;
    } catch (_) {
      await SyncService.instance.enqueue(SyncService.instance.makeUpdateRecord(r));
      return r;
    }
  }

  Future<void> deleteRecord(int id) async {
    await _deleteRecordFromCache(id);
    try {
      await _delete('/api/v1/safe/records/$id');
    } catch (_) {
      await SyncService.instance.enqueue(SyncService.instance.makeDeleteRecord(id));
    }
  }

  // SafeItem operations — online only (sub-entities, no offline queue)
  Future<SafeItem> createItem(SafeItem item) async {
    final res = await _post('/api/v1/safe/items', item.toJson());
    return SafeItem.fromJson(res);
  }

  Future<void> updateItem(SafeItem item) async {
    await _put('/api/v1/safe/items/${item.id}', item.toJson());
  }

  Future<void> deleteItem(int id) => _delete('/api/v1/safe/items/$id');

  Future<Map<String, dynamic>> importSafe(String xmlStr, {bool replace = false}) async {
    final base = await AppConfig.getApiBase();
    final token = await AppConfig.getToken();
    final uri = Uri.parse('$base/api/v1/safe/import${replace ? '?replace=true' : ''}');
    final res = await http.post(
      uri,
      headers: {HttpHeaders.authorizationHeader: 'Bearer $token', 'Content-Type': 'application/xml'},
      body: xmlStr,
    );
    _checkStatus(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<String> exportSafe() async {
    final base = await AppConfig.getApiBase();
    final token = await AppConfig.getToken();
    final res = await http.get(
      Uri.parse('$base/api/v1/safe/export'),
      headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
    );
    _checkStatus(res);
    return res.body;
  }

  // ---- Cache helpers: TOTP ----

  Future<void> _updateTotpInCache(TotpEntry e, {bool insert = false}) async {
    final raw = await CacheService.instance.read('totp.bin');
    final list = (raw is List) ? raw.cast<Map<String, dynamic>>() : <Map<String, dynamic>>[];
    final idx = list.indexWhere((x) => x['id'] == e.id);
    if (idx >= 0) {
      list[idx] = e.toJson();
    } else if (insert) {
      list.add(e.toJson());
    }
    await CacheService.instance.write('totp.bin', list);
  }

  Future<void> _replaceTotpIdInCache(int tempId, TotpEntry real) async {
    final raw = await CacheService.instance.read('totp.bin');
    if (raw is! List) return;
    final list = raw.cast<Map<String, dynamic>>();
    final idx = list.indexWhere((x) => x['id'] == tempId);
    if (idx >= 0) list[idx] = real.toJson();
    await CacheService.instance.write('totp.bin', list);
  }

  Future<void> _deleteTotpFromCache(int id) async {
    final raw = await CacheService.instance.read('totp.bin');
    if (raw is! List) return;
    final list = raw.cast<Map<String, dynamic>>()..removeWhere((x) => x['id'] == id);
    await CacheService.instance.write('totp.bin', list);
  }

  // ---- Cache helpers: Safe ----

  Future<void> _insertFolderInCache(SafeFolder f) async {
    final raw = await CacheService.instance.read('safe.bin');
    final list = (raw is List) ? raw.cast<Map<String, dynamic>>() : <Map<String, dynamic>>[];
    list.add(f.toJson());
    await CacheService.instance.write('safe.bin', list);
  }

  Future<void> _replaceFolderIdInCache(int tempId, int realId) async {
    final raw = await CacheService.instance.read('safe.bin');
    if (raw is! List) return;
    final list = raw.cast<Map<String, dynamic>>();
    final idx = list.indexWhere((f) => f['id'] == tempId);
    if (idx >= 0) list[idx]['id'] = realId;
    await CacheService.instance.write('safe.bin', list);
  }

  Future<void> _updateFolderInCache(int id, String name) async {
    final raw = await CacheService.instance.read('safe.bin');
    if (raw is! List) return;
    final list = raw.cast<Map<String, dynamic>>();
    final idx = list.indexWhere((f) => f['id'] == id);
    if (idx >= 0) list[idx]['name'] = name;
    await CacheService.instance.write('safe.bin', list);
  }

  Future<void> _deleteFolderFromCache(int id) async {
    final raw = await CacheService.instance.read('safe.bin');
    if (raw is! List) return;
    final list = raw.cast<Map<String, dynamic>>()..removeWhere((f) => f['id'] == id);
    await CacheService.instance.write('safe.bin', list);
  }

  Future<void> _insertRecordInCache(SafeRecord r) async {
    final raw = await CacheService.instance.read('safe.bin');
    if (raw is! List) return;
    final list = raw.cast<Map<String, dynamic>>();
    final idx = list.indexWhere((f) => f['id'] == r.folderId);
    if (idx >= 0) {
      final recs = ((list[idx]['records'] as List?) ?? []).cast<Map<String, dynamic>>();
      recs.add(r.toJson());
      list[idx]['records'] = recs;
    }
    await CacheService.instance.write('safe.bin', list);
  }

  Future<void> _replaceRecordIdInCache(int tempId, SafeRecord real) async {
    final raw = await CacheService.instance.read('safe.bin');
    if (raw is! List) return;
    final list = raw.cast<Map<String, dynamic>>();
    for (final f in list) {
      final recs = ((f['records'] as List?) ?? []).cast<Map<String, dynamic>>();
      final idx = recs.indexWhere((r) => r['id'] == tempId);
      if (idx >= 0) { recs[idx] = real.toJson(); f['records'] = recs; break; }
    }
    await CacheService.instance.write('safe.bin', list);
  }

  Future<void> _updateRecordInCache(SafeRecord r) async {
    final raw = await CacheService.instance.read('safe.bin');
    if (raw is! List) return;
    final list = raw.cast<Map<String, dynamic>>();
    for (final f in list) {
      final recs = ((f['records'] as List?) ?? []).cast<Map<String, dynamic>>();
      final idx = recs.indexWhere((x) => x['id'] == r.id);
      if (idx >= 0) { recs[idx] = r.toJson(); f['records'] = recs; break; }
    }
    await CacheService.instance.write('safe.bin', list);
  }

  Future<void> _deleteRecordFromCache(int id) async {
    final raw = await CacheService.instance.read('safe.bin');
    if (raw is! List) return;
    final list = raw.cast<Map<String, dynamic>>();
    for (final f in list) {
      final recs = ((f['records'] as List?) ?? []).cast<Map<String, dynamic>>();
      final before = recs.length;
      recs.removeWhere((r) => r['id'] == id);
      if (recs.length != before) { f['records'] = recs; break; }
    }
    await CacheService.instance.write('safe.bin', list);
  }

  // ---- HTTP helpers ----

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body,
      {bool auth = true}) async {
    final base = VaultManager.instance.getApiBase();
    final token = auth ? await AppConfig.getToken() : null;
    final client = VaultManager.instance.makeClient();
    try {
      final res = await client.post(
        Uri.parse('$base$path'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) HttpHeaders.authorizationHeader: 'Bearer $token',
        },
        body: jsonEncode(body),
      );
      _checkStatus(res);
      return jsonDecode(res.body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _postRaw(String path, String body) async {
    final base = VaultManager.instance.getApiBase();
    final token = await AppConfig.getToken();
    final client = VaultManager.instance.makeClient();
    try {
      final res = await client.post(
        Uri.parse('$base$path'),
        headers: {
          'Content-Type': 'application/json',
          HttpHeaders.authorizationHeader: 'Bearer $token',
        },
        body: body,
      );
      _checkStatus(res);
      return jsonDecode(res.body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<dynamic> _put(String path, Map<String, dynamic> body) async {
    final base = VaultManager.instance.getApiBase();
    final token = await AppConfig.getToken();
    final client = VaultManager.instance.makeClient();
    try {
      final res = await client.put(
        Uri.parse('$base$path'),
        headers: {
          'Content-Type': 'application/json',
          HttpHeaders.authorizationHeader: 'Bearer $token',
        },
        body: jsonEncode(body),
      );
      _checkStatus(res);
      if (res.body.isEmpty || res.statusCode == 204) return null;
      return jsonDecode(res.body);
    } finally {
      client.close();
    }
  }

  Future<void> _delete(String path) async {
    final base = VaultManager.instance.getApiBase();
    final token = await AppConfig.getToken();
    final client = VaultManager.instance.makeClient();
    try {
      final res = await client.delete(
        Uri.parse('$base$path'),
        headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
      );
      _checkStatus(res);
    } finally {
      client.close();
    }
  }

  Future<List<Map<String, dynamic>>> _getList(String path) async {
    final base = VaultManager.instance.getApiBase();
    final token = await AppConfig.getToken();
    final client = VaultManager.instance.makeClient();
    try {
      final res = await client.get(
        Uri.parse('$base$path'),
        headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
      );
      _checkStatus(res);
      return (jsonDecode(res.body) as List<dynamic>).cast<Map<String, dynamic>>();
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final base = VaultManager.instance.getApiBase();
    final token = await AppConfig.getToken();
    final client = VaultManager.instance.makeClient();
    try {
      final res = await client.get(
        Uri.parse('$base$path'),
        headers: {if (token != null) HttpHeaders.authorizationHeader: 'Bearer $token'},
      );
      _checkStatus(res);
      return jsonDecode(res.body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  // ── Snapshots ──────────────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> getSnapshots() async => _getList('/api/v1/snapshots');
  Future<Map<String, dynamic>> triggerSnapshot({String type = 'full'}) async =>
      _post('/api/v1/snapshots', {'type': type});
  Future<Map<String, dynamic>> restoreSnapshot(int id) async =>
      _post('/api/v1/snapshots/$id/restore', {});
  Future<void> deleteSnapshot(int id) async => _delete('/api/v1/snapshots/$id');
  Future<Map<String, dynamic>> getBackupHealth() async => _get('/api/v1/backup/health');

  void _checkStatus(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    String msg = res.body;
    try {
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      msg = j['error'] as String? ?? msg;
    } catch (_) {}
    throw ApiException(res.statusCode, msg);
  }
}
