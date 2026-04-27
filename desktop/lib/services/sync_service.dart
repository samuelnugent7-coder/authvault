import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import '../models/safe_node.dart';
import 'vault_manager.dart';
import '../models/totp_entry.dart';
import 'cache_service.dart';

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// Mutation model
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

enum MutationOp { create, update, delete }

enum MutationResource { totp, safeFolder, safeRecord }

class PendingMutation {
  final String id;
  final int timestampMs;
  final MutationOp op;
  final MutationResource resource;
  final Map<String, dynamic> data;
  final int? tempId; // negative temp ID used for offline-created items

  const PendingMutation({
    required this.id,
    required this.timestampMs,
    required this.op,
    required this.resource,
    required this.data,
    this.tempId,
  });

  factory PendingMutation.fromJson(Map<String, dynamic> j) => PendingMutation(
        id: j['id'] as String,
        timestampMs: j['ts'] as int,
        op: MutationOp.values[j['op'] as int],
        resource: MutationResource.values[j['res'] as int],
        data: Map<String, dynamic>.from(j['data'] as Map),
        tempId: j['tempId'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'ts': timestampMs,
        'op': op.index,
        'res': resource.index,
        'data': data,
        if (tempId != null) 'tempId': tempId,
      };
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// SyncService
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

/// Manages the offline mutation queue and background sync.
///
///   await SyncService.instance.init();  // once at startup
///   SyncService.instance.sync();        // manual flush
///
/// NOTE: SyncService makes HTTP calls directly (not via ApiService) to avoid
/// a circular import (ApiService â†’ SyncService â†’ ApiService).
class SyncService extends ChangeNotifier {
  SyncService._();
  static final SyncService instance = SyncService._();

  static const _mutFile = 'mutations.bin';
  static const _uuid = Uuid();

  List<PendingMutation> _queue = [];
  bool _syncing = false;
  bool _online = true;
  String? _lastError;
  DateTime? _lastSync;

  Timer? _timer;
  StreamSubscription? _connectivitySub;

  int get pendingCount => _queue.length;
  bool get syncing => _syncing;
  bool get online => _online;
  String? get lastError => _lastError;
  DateTime? get lastSync => _lastSync;

  // â”€â”€ Lifecycle â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> init() async {
    await _loadQueue();

    _connectivitySub =
        Connectivity().onConnectivityChanged.listen((results) async {
      final wasOffline = !_online;
      _online = results.any((r) => r != ConnectivityResult.none);
      if (wasOffline && _online && _queue.isNotEmpty) unawaited(sync());
      notifyListeners();
    });

    final result = await Connectivity().checkConnectivity();
    _online = result.any((r) => r != ConnectivityResult.none);

    _timer = Timer.periodic(
        const Duration(seconds: 30), (_) { if (_queue.isNotEmpty) unawaited(sync()); });

    if (_queue.isNotEmpty) unawaited(sync());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _connectivitySub?.cancel();
    super.dispose();
  }

  // â”€â”€ Manual trigger â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> sync() async {
    if (_syncing) return;
    _syncing = true;
    _lastError = null;
    notifyListeners();

    try {
      final available = await _isOnline();
      if (!available) {
        _online = false;
        return;
      }
      _online = true;

      final snapshot = List<PendingMutation>.from(_queue);
      for (final m in snapshot) {
        try {
          await _apply(m);
          _queue.removeWhere((x) => x.id == m.id);
          await _saveQueue();
          notifyListeners();
        } catch (e) {
          _lastError = e.toString();
          break; // preserve ordering â€” stop on first failure
        }
      }

      if (_queue.isEmpty) {
        await _refreshCaches();
        _lastSync = DateTime.now();
      }
    } catch (e) {
      _lastError = e.toString();
      _online = false;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  // â”€â”€ Queue management â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> enqueue(PendingMutation m) async {
    _queue.add(m);
    await _saveQueue();
    notifyListeners();
  }

  Future<void> _loadQueue() async {
    final raw = await CacheService.instance.read(_mutFile);
    if (raw is List) {
      _queue = raw
          .cast<Map<String, dynamic>>()
          .map(PendingMutation.fromJson)
          .toList();
    }
  }

  Future<void> _saveQueue() async {
    await CacheService.instance.write(
        _mutFile, _queue.map((m) => m.toJson()).toList());
  }

  // â”€â”€ Mutation factories â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  PendingMutation makeCreateTotp(TotpEntry e, int tempId) =>
      _m(MutationOp.create, MutationResource.totp, e.toJson(), tempId: tempId);
  PendingMutation makeUpdateTotp(TotpEntry e) =>
      _m(MutationOp.update, MutationResource.totp, e.toJson());
  PendingMutation makeDeleteTotp(int id) =>
      _m(MutationOp.delete, MutationResource.totp, {'id': id});

  PendingMutation makeCreateFolder(String name, int tempId) =>
      _m(MutationOp.create, MutationResource.safeFolder, {'name': name},
          tempId: tempId);
  PendingMutation makeUpdateFolder(int id, String name) =>
      _m(MutationOp.update, MutationResource.safeFolder,
          {'id': id, 'name': name});
  PendingMutation makeDeleteFolder(int id) =>
      _m(MutationOp.delete, MutationResource.safeFolder, {'id': id});

  PendingMutation makeCreateRecord(SafeRecord r, int tempId) =>
      _m(MutationOp.create, MutationResource.safeRecord, r.toJson(),
          tempId: tempId);
  PendingMutation makeUpdateRecord(SafeRecord r) =>
      _m(MutationOp.update, MutationResource.safeRecord, r.toJson());
  PendingMutation makeDeleteRecord(int id) =>
      _m(MutationOp.delete, MutationResource.safeRecord, {'id': id});

  PendingMutation _m(MutationOp op, MutationResource res,
          Map<String, dynamic> data,
          {int? tempId}) =>
      PendingMutation(
        id: _uuid.v4(),
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        op: op,
        resource: res,
        data: data,
        tempId: tempId,
      );

  // â”€â”€ Apply a mutation via direct HTTP â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _apply(PendingMutation m) async {
    switch (m.resource) {
      case MutationResource.totp:
        await _applyTotp(m);
      case MutationResource.safeFolder:
        await _applyFolder(m);
      case MutationResource.safeRecord:
        await _applyRecord(m);
    }
  }

  Future<void> _applyTotp(PendingMutation m) async {
    final entry = TotpEntry.fromJson(m.data);
    switch (m.op) {
      case MutationOp.create:
        final created = TotpEntry.fromJson(await _post('/api/v1/totp', entry.toJson()));
        await _patchTotpCache(m.tempId!, created);
      case MutationOp.update:
        try {
          await _put('/api/v1/totp/${entry.id}', entry.toJson());
        } on _HttpError catch (e) {
          if (e.status == 404) {
            await _post('/api/v1/totp', entry.toJson());
          } else { rethrow; }
        }
      case MutationOp.delete:
        try {
          await _delete('/api/v1/totp/${m.data['id']}');
        } on _HttpError catch (e) {
          if (e.status != 404) rethrow;
        }
    }
  }

  Future<void> _applyFolder(PendingMutation m) async {
    switch (m.op) {
      case MutationOp.create:
        final res = await _post('/api/v1/safe/folders', {'name': m.data['name']});
        await _patchFolderCache(m.tempId!, res['id'] as int);
      case MutationOp.update:
        try {
          await _put('/api/v1/safe/folders/${m.data['id']}', {'name': m.data['name']});
        } on _HttpError catch (e) {
          if (e.status != 404) rethrow;
        }
      case MutationOp.delete:
        try {
          await _delete('/api/v1/safe/folders/${m.data['id']}');
        } on _HttpError catch (e) {
          if (e.status != 404) rethrow;
        }
    }
  }

  Future<void> _applyRecord(PendingMutation m) async {
    final record = SafeRecord.fromJson(m.data);
    switch (m.op) {
      case MutationOp.create:
        final created = SafeRecord.fromJson(
            await _post('/api/v1/safe/records', record.toJson()));
        await _patchRecordCache(m.tempId!, created);
      case MutationOp.update:
        try {
          await _put('/api/v1/safe/records/${record.id}', record.toJson());
        } on _HttpError catch (e) {
          if (e.status == 404) {
            await _post('/api/v1/safe/records', record.toJson());
          } else { rethrow; }
        }
      case MutationOp.delete:
        try {
          await _delete('/api/v1/safe/records/${m.data['id']}');
        } on _HttpError catch (e) {
          if (e.status != 404) rethrow;
        }
    }
  }

  // â”€â”€ Cache patching â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _patchTotpCache(int tempId, TotpEntry real) async {
    final raw = await CacheService.instance.read('totp.bin');
    if (raw is! List) return;
    final list = raw.cast<Map<String, dynamic>>();
    final i = list.indexWhere((e) => e['id'] == tempId);
    if (i >= 0) list[i] = real.toJson();
    await CacheService.instance.write('totp.bin', list);
  }

  Future<void> _patchFolderCache(int tempId, int realId) async {
    final raw = await CacheService.instance.read('safe.bin');
    if (raw is! List) return;
    final list = raw.cast<Map<String, dynamic>>();
    final i = list.indexWhere((f) => f['id'] == tempId);
    if (i >= 0) list[i]['id'] = realId;
    await CacheService.instance.write('safe.bin', list);
  }

  Future<void> _patchRecordCache(int tempId, SafeRecord real) async {
    final raw = await CacheService.instance.read('safe.bin');
    if (raw is! List) return;
    final folders = raw.cast<Map<String, dynamic>>();
    for (final f in folders) {
      final recs =
          ((f['records'] as List?) ?? []).cast<Map<String, dynamic>>();
      final i = recs.indexWhere((r) => r['id'] == tempId);
      if (i >= 0) { recs[i] = real.toJson(); f['records'] = recs; break; }
    }
    await CacheService.instance.write('safe.bin', folders);
  }

  // â”€â”€ Full cache refresh after successful sync â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _refreshCaches() async {
    try {
      final totpRaw = await _getList('/api/v1/totp');
      await CacheService.instance.write('totp.bin', totpRaw);
      final safeRaw = await _getList('/api/v1/safe');
      await CacheService.instance.write('safe.bin', safeRaw);
    } catch (_) {}
  }

  // â”€â”€ HTTP helpers (direct, no ApiService dependency) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<bool> _isOnline() async {
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

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body) async {
    final base = VaultManager.instance.getApiBase();
    final token = await VaultManager.instance.getToken();
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
      if (res.statusCode >= 400) throw _HttpError(res.statusCode);
      return decoded;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _put(
      String path, Map<String, dynamic> body) async {
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
      if (res.statusCode >= 400) throw _HttpError(res.statusCode);
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
      if (res.statusCode >= 400) throw _HttpError(res.statusCode);
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
      if (res.statusCode >= 400) throw _HttpError(res.statusCode);
      final decoded = jsonDecode(res.body);
      if (decoded is List) return decoded.cast<Map<String, dynamic>>();
      return [];
    } finally {
      client.close();
    }
  }
}

class _HttpError implements Exception {
  final int status;
  const _HttpError(this.status);
}

