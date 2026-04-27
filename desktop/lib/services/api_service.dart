import 'dart:convert';
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

  Future<UserInfo> login(String username, String password) async {
    final res = await _post('/api/v1/auth/login',
        {'username': username.trim().toLowerCase(), 'password': password},
        auth: false);
    final token = res['token'] as String;
    await VaultManager.instance.setToken(token);
    CacheService.instance.setKeyFromToken(token);
    final info = UserInfo.fromJson(res);
    await VaultManager.instance.setUserInfo(info);
    return info;
  }

  Future<UserInfo?> getMe() async {
    try {
      final res = await _get('/api/v1/auth/me');
      return UserInfo.fromJson(res);
    } catch (_) {
      return null;
    }
  }

  Future<void> logout() async {
    final token = await AppConfig.getToken();
    if (token == null) return;
    try { await _post('/api/v1/auth/logout', {}); } catch (_) {}
    await AppConfig.clearToken();
    await CacheService.instance.clearAll();
  }

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
      return TotpEntry.fromJson(res);
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

  Future<SafeFolder> createFolder(String name) async {
    final tempId = _nextTempId;
    final optimistic = SafeFolder(id: tempId, name: name, records: []);
    await _insertFolderInCache(optimistic);
    try {
      final res = await _post('/api/v1/safe/folders', {'name': name});
      final created = SafeFolder.fromJson(res);
      await _replaceFolderIdInCache(tempId, created.id!);
      return created;
    } catch (_) {
      await SyncService.instance.enqueue(SyncService.instance.makeCreateFolder(name, tempId));
      return optimistic;
    }
  }

  Future<SafeFolder> updateFolder(int id, String name) async {
    await _updateFolderInCache(id, name);
    try {
      final res = await _put('/api/v1/safe/folders/$id', {'name': name});
      return SafeFolder.fromJson(res);
    } catch (_) {
      await SyncService.instance.enqueue(SyncService.instance.makeUpdateFolder(id, name));
      return SafeFolder(id: id, name: name, records: []);
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
      id: tempId, folderId: r.folderId, title: r.title,
      username: r.username, password: r.password, url: r.url, notes: r.notes,
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
      return SafeRecord.fromJson(res);
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

  Future<Map<String, dynamic>> importSafe(String xml, {bool replace = false}) async =>
      await _postRaw('/api/v1/safe/import?replace=$replace', xml,
          contentType: 'application/xml');

  Future<String> exportSafe() async {
    final base = VaultManager.instance.getApiBase();
    final token = await VaultManager.instance.getToken();
    final client = VaultManager.instance.makeClient();
    try {
      final res = await client.get(
        Uri.parse('$base/api/v1/safe/export'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode != 200) throw ApiException(res.statusCode, res.body);
      return res.body;
    } finally {
      client.close();
    }
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
    final token = auth ? await VaultManager.instance.getToken() : null;
    final client = VaultManager.instance.makeClient();
    try {
      final res = await client.post(
        Uri.parse('$base$path'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode(body),
      );
      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode >= 400) throw ApiException(res.statusCode, decoded['error'] ?? res.body);
      return decoded;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _postRaw(String path, String body,
      {String contentType = 'application/json'}) async {
    final base = VaultManager.instance.getApiBase();
    final token = await VaultManager.instance.getToken();
    final client = VaultManager.instance.makeClient();
    try {
      final res = await client.post(
        Uri.parse('$base$path'),
        headers: {
          'Content-Type': contentType,
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: body,
      );
      if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
      return jsonDecode(res.body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _put(String path, Map<String, dynamic> body) async {
    final base = VaultManager.instance.getApiBase();
    final token = await VaultManager.instance.getToken();
    final client = VaultManager.instance.makeClient();
    try {
      final res = await client.put(
        Uri.parse('$base$path'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode(body),
      );
      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode >= 400) throw ApiException(res.statusCode, decoded['error'] ?? res.body);
      return decoded;
    } finally {
      client.close();
    }
  }

  Future<void> _delete(String path) async {
    final base = VaultManager.instance.getApiBase();
    final token = await VaultManager.instance.getToken();
    final client = VaultManager.instance.makeClient();
    try {
      final res = await client.delete(
        Uri.parse('$base$path'),
        headers: {if (token != null) 'Authorization': 'Bearer $token'},
      );
      if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
    } finally {
      client.close();
    }
  }

  // ---- Admin ----

  Future<List<Map<String, dynamic>>> adminListUsers() =>
      _getList('/api/v1/admin/users');

  Future<Map<String, dynamic>> adminCreateUser(String username, String password,
          {bool isAdmin = false}) =>
      _post('/api/v1/admin/users',
          {'username': username, 'password': password, 'is_admin': isAdmin});

  Future<Map<String, dynamic>> adminUpdateUser(int id,
          {String? password, bool? isAdmin}) =>
      _put('/api/v1/admin/users/$id',
          {if (password != null) 'password': password, if (isAdmin != null) 'is_admin': isAdmin});

  Future<void> adminDeleteUser(int id) => _delete('/api/v1/admin/users/$id');

  Future<Map<String, dynamic>> adminGetPermissions(int id) =>
      _get('/api/v1/admin/users/$id/permissions');

  Future<void> adminSetPermissions(int id, UserPermissions perms) async {
    await _put('/api/v1/admin/users/$id/permissions', perms.toJson());
  }

  // ---- Audit logs ----
  Future<List<Map<String, dynamic>>> getAuditLogs({int limit = 100}) =>
      _getList('/api/v1/audit?limit=$limit');

  // ---- Sessions ----
  Future<List<Map<String, dynamic>>> getSessions() =>
      _getList('/api/v1/sessions');

  Future<void> revokeSession(int id) => _delete('/api/v1/sessions/$id');

  // ---- Password health ----
  Future<Map<String, dynamic>> getPasswordHealth({bool hibp = false}) =>
      _get('/api/v1/health/passwords${hibp ? '?hibp=true' : ''}');

  // ---- SSH keys ----
  Future<List<Map<String, dynamic>>> getSSHKeys() =>
      _getList('/api/v1/ssh');

  Future<Map<String, dynamic>> createSSHKey(Map<String, dynamic> data) =>
      _post('/api/v1/ssh', data);

  Future<Map<String, dynamic>> updateSSHKey(int id, Map<String, dynamic> data) =>
      _put('/api/v1/ssh/$id', data);

  Future<void> deleteSSHKey(int id) => _delete('/api/v1/ssh/$id');

  // ---- Attachments ----
  Future<List<Map<String, dynamic>>> getAttachments(int recordId) =>
      _getList('/api/v1/attachments?record_id=$recordId');

  Future<Map<String, dynamic>> uploadAttachment(Map<String, dynamic> data) =>
      _post('/api/v1/attachments', data);

  Future<void> deleteAttachment(int id) => _delete('/api/v1/attachments/$id');

  Future<Map<String, dynamic>> getAttachmentData(int id) =>
      _get('/api/v1/attachments/$id/data');

  // ---- S3 config ----
  Future<Map<String, dynamic>> getS3Config() => _get('/api/v1/s3/config');

  Future<void> setS3Config(Map<String, dynamic> cfg) async {
    await _put('/api/v1/s3/config', cfg);
  }

  // ---- Snapshots ----
  Future<Map<String, dynamic>> getSnapshots() => _get('/api/v1/snapshots');

  Future<Map<String, dynamic>> triggerSnapshot({String type = 'full'}) =>
      _post('/api/v1/snapshots', {'type': type});

  Future<void> restoreSnapshot(int id) async {
    await _post('/api/v1/snapshots/$id/restore', {});
  }

  Future<void> deleteSnapshot(int id) async {
    await _delete('/api/v1/snapshots/$id');
  }

  // ---- Backup Health ----
  Future<Map<String, dynamic>> getBackupHealth() => _get('/api/v1/backup/health');

  // ---- Helpers ----

  Future<Map<String, dynamic>> _get(String path) async {
    final base = VaultManager.instance.getApiBase();
    final token = await VaultManager.instance.getToken();
    final client = VaultManager.instance.makeClient();
    try {
      final res = await client.get(
        Uri.parse('$base$path'),
        headers: {if (token != null) 'Authorization': 'Bearer $token'},
      );
      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode >= 400) throw ApiException(res.statusCode, decoded['error'] ?? res.body);
      return decoded;
    } finally {
      client.close();
    }
  }

  Future<List<Map<String, dynamic>>> _getList(String path) async {
    final base = VaultManager.instance.getApiBase();
    final token = await VaultManager.instance.getToken();
    final client = VaultManager.instance.makeClient();
    try {
      final res = await client.get(
        Uri.parse('$base$path'),
        headers: {if (token != null) 'Authorization': 'Bearer $token'},
      );
      if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
      final decoded = jsonDecode(res.body);
      if (decoded is List) return decoded.cast<Map<String, dynamic>>();
      return [];
    } finally {
      client.close();
    }
  }

  // ---- Password Generator ----
  Future<Map<String, dynamic>> generatePassword({
    int length = 16,
    bool uppercase = true,
    bool digits = true,
    bool symbols = true,
    bool noAmbiguous = false,
  }) =>
      _post('/api/v1/generator', {
        'length': length,
        'uppercase': uppercase,
        'digits': digits,
        'symbols': symbols,
        'no_ambiguous': noAmbiguous,
      });

  // ---- TOTP QR ----
  Future<String> getTotpQR(int id) async {
    final m = await _get('/api/v1/totp/$id/qr');
    return m['uri'] as String? ?? '';
  }

  // ---- Recycle Bin ----
  Future<List<Map<String, dynamic>>> getRecycleBin() =>
      _getList('/api/v1/recycle-bin');

  Future<Map<String, dynamic>> restoreBinItem(int id) =>
      _post('/api/v1/recycle-bin/$id/restore', {});

  Future<void> deleteBinItem(int id) => _delete('/api/v1/recycle-bin/$id');

  Future<void> emptyRecycleBin() async {
    final base = VaultManager.instance.getApiBase();
    final token = await VaultManager.instance.getToken();
    final client = VaultManager.instance.makeClient();
    try {
      await client.delete(
        Uri.parse('$base/api/v1/recycle-bin'),
        headers: {if (token != null) 'Authorization': 'Bearer $token'},
      );
    } finally {
      client.close();
    }
  }

  // ---- Password History & Versions ----
  Future<List<Map<String, dynamic>>> getPasswordHistory(int recordId) =>
      _getList('/api/v1/safe/records/$recordId/history');

  Future<List<Map<String, dynamic>>> getRecordVersions(int recordId) =>
      _getList('/api/v1/safe/records/$recordId/versions');

  Future<Map<String, dynamic>> restoreRecordVersion(int versionId) =>
      _post('/api/v1/safe/records/versions/$versionId/restore', {});

  // ---- Secure Notes ----
  Future<List<Map<String, dynamic>>> getNotes() => _getList('/api/v1/notes');

  Future<Map<String, dynamic>> createNote(Map<String, dynamic> note) =>
      _post('/api/v1/notes', note);

  Future<Map<String, dynamic>> getNote(int id) => _get('/api/v1/notes/$id');

  Future<Map<String, dynamic>> updateNote(int id, Map<String, dynamic> note) =>
      _put('/api/v1/notes/$id', note);

  Future<void> deleteNote(int id) => _delete('/api/v1/notes/$id');

  // ---- Tags ----
  Future<List<Map<String, dynamic>>> getTags() => _getList('/api/v1/tags');

  Future<Map<String, dynamic>> createTag(String name, String color) =>
      _post('/api/v1/tags', {'name': name, 'color': color});

  Future<Map<String, dynamic>> updateTag(
          int id, String name, String color) =>
      _put('/api/v1/tags/$id', {'name': name, 'color': color});

  Future<void> deleteTag(int id) => _delete('/api/v1/tags/$id');

  Future<void> setRecordTags(int recordId, List<int> tagIds) async {
    await _put('/api/v1/safe/records/$recordId/tags', {'tag_ids': tagIds});
  }

  // ---- Folder Shares ----
  Future<List<Map<String, dynamic>>> getFolderShares(int folderId) =>
      _getList('/api/v1/safe/folders/$folderId/shares');

  Future<void> addFolderShare(
      int folderId, int userId, bool canWrite) async {
    await _post('/api/v1/safe/folders/$folderId/shares',
        {'user_id': userId, 'can_write': canWrite});
  }

  Future<void> removeFolderShare(int folderId, int userId) async {
    final base = VaultManager.instance.getApiBase();
    final token = await VaultManager.instance.getToken();
    final client = VaultManager.instance.makeClient();
    try {
      await client.delete(
        Uri.parse('$base/api/v1/safe/folders/$folderId/shares/$userId'),
        headers: {if (token != null) 'Authorization': 'Bearer $token'},
      );
    } finally {
      client.close();
    }
  }

  // ---- Dashboard ----
  Future<Map<String, dynamic>> getDashboard() => _get('/api/v1/dashboard');

  // ---- Share Links ----
  Future<List<Map<String, dynamic>>> getShareLinks() =>
      _getList('/api/v1/share-links');

  Future<Map<String, dynamic>> createShareLink(
      int recordId, bool oneTime, int ttlSeconds) =>
      _post('/api/v1/share-links',
          {'record_id': recordId, 'one_time': oneTime, 'ttl_seconds': ttlSeconds});

  Future<void> deleteShareLink(int id) => _delete('/api/v1/share-links/$id');

  // ---- API Keys ----
  Future<List<Map<String, dynamic>>> getApiKeys() =>
      _getList('/api/v1/api-keys');

  Future<Map<String, dynamic>> createApiKey(String name,
      {int expiresAt = 0}) =>
      _post('/api/v1/api-keys', {'name': name, 'expires_at': expiresAt});

  Future<void> revokeApiKey(int id) async {
    await _post('/api/v1/api-keys/$id/revoke', {});
  }

  Future<void> deleteApiKey(int id) => _delete('/api/v1/api-keys/$id');

  // ---- Email Config ----
  Future<Map<String, dynamic>> getEmailConfig() =>
      _get('/api/v1/email/config');

  Future<void> updateEmailConfig(Map<String, dynamic> cfg) async {
    await _put('/api/v1/email/config', cfg);
  }

  Future<void> testEmail() async {
    await _post('/api/v1/email/test', {});
  }

  // ---- CSV Import ----
  Future<Map<String, dynamic>> importCsv(String csvContent,
      {String format = 'generic'}) =>
      _post('/api/v1/import/csv?format=$format', {'data': csvContent});

  // ---- Data Integrity ----
  Future<Map<String, dynamic>> runIntegrityCheck() =>
      _post('/api/v1/admin/integrity', {});

  // ---- Duress Admin ----
  Future<void> setDuressPassword(String password) async {
    await _put('/api/v1/admin/duress', {'password': password});
  }

  Future<List<Map<String, dynamic>>> getDecoyFolders() =>
      _getList('/api/v1/admin/duress/folders');

  Future<void> setDecoyFolder(int id, bool isDecoy) async {
    await _put('/api/v1/admin/duress/folders/$id', {'is_decoy': isDecoy});
  }

  // ---- User Expiry ----
  Future<void> setUserExpiry(int userId, int expiresAt) async {
    await _put('/api/v1/admin/users/$userId/expiry',
        {'expires_at': expiresAt});
  }
}
