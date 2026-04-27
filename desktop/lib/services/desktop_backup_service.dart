import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'vault_manager.dart';

/// Progress callback: (done, total, bytesUploaded, currentFile)
typedef BackupProgressCallback = void Function(
    int done, int total, int bytesUploaded, String currentFile);

// ── Config ──────────────────────────────────────────────────────────────────

class DesktopBackupConfig {
  List<String> includePaths;
  List<String> excludePatterns;
  int scheduleHours; // 0 = manual only
  String scheduleTime; // "HH:MM"
  bool enabled;

  DesktopBackupConfig({
    List<String>? includePaths,
    List<String>? excludePatterns,
    this.scheduleHours = 0,
    this.scheduleTime = '02:00',
    this.enabled = true,
  })  : includePaths = includePaths ?? _defaultIncludes(),
        excludePatterns = excludePatterns ?? _defaultExcludes();

  static List<String> _defaultIncludes() {
    if (!Platform.isWindows) return [];
    final home = Platform.environment['USERPROFILE'] ?? 'C:\\Users\\User';
    return [
      '$home\\Documents',
      '$home\\Pictures',
      '$home\\Desktop',
      '$home\\Downloads',
    ];
  }

  static List<String> _defaultExcludes() => [
        '*.tmp',
        '*.temp',
        '~\$*',
        'Thumbs.db',
        'desktop.ini',
        '\$RECYCLE.BIN',
        'System Volume Information',
        'node_modules',
        '.git',
      ];

  Map<String, dynamic> toJson() => {
        'include_paths': includePaths,
        'exclude_patterns': excludePatterns,
        'schedule_hours': scheduleHours,
        'schedule_time': scheduleTime,
        'enabled': enabled,
      };

  factory DesktopBackupConfig.fromJson(Map<String, dynamic> j) =>
      DesktopBackupConfig(
        includePaths: List<String>.from(j['include_paths'] as List? ?? []),
        excludePatterns:
            List<String>.from(j['exclude_patterns'] as List? ?? []),
        scheduleHours: (j['schedule_hours'] as int?) ?? 0,
        scheduleTime: (j['schedule_time'] as String?) ?? '02:00',
        enabled: (j['enabled'] as bool?) ?? true,
      );
}

// ── Result ────────────────────────────────────────────────────────────────

class DesktopBackupResult {
  final int uploaded;
  final int newFiles;
  final int changedFiles;
  final int skipped;
  final int errors;
  final int totalBytes;
  final String? errorMessage;
  final List<String> failedFiles;

  const DesktopBackupResult({
    required this.uploaded,
    required this.newFiles,
    required this.changedFiles,
    required this.skipped,
    required this.errors,
    required this.totalBytes,
    this.errorMessage,
    this.failedFiles = const [],
  });

  factory DesktopBackupResult.error(String msg) => DesktopBackupResult(
        uploaded: 0,
        newFiles: 0,
        changedFiles: 0,
        skipped: 0,
        errors: 1,
        totalBytes: 0,
        errorMessage: msg,
      );

  bool get isError => errorMessage != null;

  String get summary {
    if (isError) return 'Error: $errorMessage';
    final parts = <String>[];
    if (newFiles > 0) parts.add('$newFiles new');
    if (changedFiles > 0) parts.add('$changedFiles changed');
    if (skipped > 0) parts.add('$skipped unchanged');
    if (errors > 0) parts.add('$errors errors');
    final files = parts.isEmpty ? 'Nothing to upload' : parts.join(', ');
    final bytes = _human(totalBytes);
    return uploaded > 0 ? '$files — $bytes uploaded' : files;
  }

  static String _human(int b) {
    if (b < 1024) return '$b B';
    if (b < 1 << 20) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1 << 30) return '${(b >> 20)} MB';
    return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  }
}

// ── Service ───────────────────────────────────────────────────────────────

class DesktopBackupService {
  static const _keyConfig = 'desktop_backup_config';
  static const _keyLastResult = 'desktop_backup_last_result';
  static const _keyDeviceId = 'desktop_backup_device_id';

  // ---- Config persistence ------------------------------------------------

  static Future<DesktopBackupConfig> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyConfig);
    if (raw == null) return DesktopBackupConfig();
    try {
      return DesktopBackupConfig.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return DesktopBackupConfig();
    }
  }

  static Future<void> saveConfig(DesktopBackupConfig cfg) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyConfig, jsonEncode(cfg.toJson()));
    // Also push config to server so the next run is consistent.
    _pushConfigToServer(cfg).ignore();
  }

  static Future<String> _deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_keyDeviceId);
    if (id != null) return id;
    id = 'windows-${Platform.environment['COMPUTERNAME'] ?? 'desktop'}';
    await prefs.setString(_keyDeviceId, id);
    return id;
  }

  static Future<void> _pushConfigToServer(DesktopBackupConfig cfg) async {
    try {
      final token = await VaultManager.instance.getToken();
      if (token == null) return;
      final apiBase = VaultManager.instance.getBackupApiBase();
      final deviceId = await _deviceId();
      final body = <String, dynamic>{'device_id': deviceId};
      body.addAll(cfg.toJson());
      await http.put(
        Uri.parse('$apiBase/api/v1/backup/config'),
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {
      // best-effort
    }
  }

  // ---- Last result --------------------------------------------------------

  static Future<void> _saveResult(DesktopBackupResult r) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLastResult, jsonEncode({
      'uploaded': r.uploaded,
      'new_files': r.newFiles,
      'changed_files': r.changedFiles,
      'skipped': r.skipped,
      'errors': r.errors,
      'total_bytes': r.totalBytes,
      'ran_at': DateTime.now().toIso8601String(),
      'failed': r.failedFiles.take(50).toList(),
    }));
  }

  static Future<Map<String, dynamic>?> loadLastResult() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyLastResult);
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  // ---- File scanning -------------------------------------------------------

  /// Returns all non-excluded files under the configured include paths.
  static Future<List<_FileMeta>> scanFiles(DesktopBackupConfig cfg) async {
    final result = <_FileMeta>[];
    final visited = <String>{};

    for (final root in cfg.includePaths) {
      final dir = Directory(root);
      if (!await dir.exists()) continue;
      await _walkDir(dir, result, cfg.excludePatterns, visited);
    }
    return result;
  }

  static Future<void> _walkDir(
    Directory dir,
    List<_FileMeta> result,
    List<String> excludePatterns,
    Set<String> visited,
  ) async {
    String real;
    try {
      real = await dir.resolveSymbolicLinks();
    } catch (_) {
      real = dir.path;
    }
    if (!visited.add(real)) return;

    List<FileSystemEntity> entries;
    try {
      entries =
          await dir.list(recursive: false, followLinks: true).toList();
    } catch (_) {
      return;
    }

    for (final entity in entries) {
      final name = p.basename(entity.path);
      if (_matchesAny(name, excludePatterns)) continue;
      if (_matchesAny(entity.path, excludePatterns)) continue;

      if (entity is Directory) {
        await _walkDir(entity, result, excludePatterns, visited);
      } else if (entity is File) {
        try {
          final stat = await entity.stat();
          if (stat.size >= 0) {
            result.add(_FileMeta(
              path: entity.path,
              size: stat.size,
              mtime: stat.modified.millisecondsSinceEpoch ~/ 1000,
            ));
          }
        } catch (_) {}
      } else if (entity is Link) {
        await _walkDir(Directory(entity.path), result, excludePatterns, visited);
      }
    }
  }

  /// Returns whether [name] matches any of the glob-like [patterns].
  /// Supports * wildcard only (simple fnmatch-style).
  static bool _matchesAny(String name, List<String> patterns) {
    final base = p.basename(name);
    for (final pat in patterns) {
      if (_glob(base, pat) || _glob(name, pat)) return true;
    }
    return false;
  }

  static bool _glob(String str, String pattern) {
    // Convert simple glob to regex: * → .*, ? → .
    final regexStr = pattern
        .replaceAll(r'\', r'\\')
        .replaceAll('.', r'\.')
        .replaceAll('*', '.*')
        .replaceAll('?', '.');
    try {
      return RegExp('^$regexStr\$', caseSensitive: false).hasMatch(str);
    } catch (_) {
      return str == pattern;
    }
  }

  // ---- Backup run ----------------------------------------------------------

  static Future<DesktopBackupResult> runBackup({
    required DesktopBackupConfig cfg,
    BackupProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    final token = await VaultManager.instance.getToken();
    if (token == null) {
      return DesktopBackupResult.error(
          'Not authenticated — open AuthVault and log in first');
    }
    final apiBase = VaultManager.instance.getBackupApiBase();
    final deviceId = await _deviceId();

    // 1. Scan
    onProgress?.call(0, 0, 0, 'Scanning folders…');
    final allFiles = await scanFiles(cfg);
    if (allFiles.isEmpty) {
      return DesktopBackupResult.error(
          'No files found in the configured source folders.');
    }
    onProgress?.call(0, allFiles.length, 0,
        'Found ${allFiles.length} files — checking server…');

    // 2. Check (batches of 500)
    const batchSize = 500;
    final needsUpload = <String>[];
    int newCount = 0;
    int changedCount = 0;
    int unchangedCount = 0;

    for (int start = 0; start < allFiles.length; start += batchSize) {
      if (isCancelled?.call() == true) break;
      final end = (start + batchSize).clamp(0, allFiles.length);
      final batch = allFiles.sublist(start, end);

      final checkBody = jsonEncode({
        'device_id': deviceId,
        'files': batch.map((f) => {
              'path': f.path,
              'size': f.size,
              'mtime': f.mtime,
              'sha256': '',
            }).toList(),
      });

      try {
        final res = await http.post(
          Uri.parse('$apiBase/api/v1/backup/check'),
          headers: {
            HttpHeaders.authorizationHeader: 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: checkBody,
        ).timeout(const Duration(seconds: 60));

        if (res.statusCode != 200) {
          return DesktopBackupResult.error('Check failed: ${res.body}');
        }
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        needsUpload.addAll(List<String>.from(data['needs_upload'] as List));
        newCount += (data['new_count'] as int?) ?? 0;
        changedCount += (data['changed_count'] as int?) ?? 0;
        unchangedCount += (data['unchanged_count'] as int?) ?? 0;
      } catch (e) {
        return DesktopBackupResult.error('Check error: $e');
      }
    }

    if (needsUpload.isEmpty) {
      final result = DesktopBackupResult(
        uploaded: 0,
        newFiles: newCount,
        changedFiles: changedCount,
        skipped: unchangedCount,
        errors: 0,
        totalBytes: 0,
      );
      await _saveResult(result);
      return result;
    }

    final fileMap = {for (final f in allFiles) f.path: f};

    // 3. Upload
    int uploaded = 0;
    int errors = 0;
    int totalBytes = 0;
    int done = 0;
    final failedFiles = <String>[];

    for (final path in needsUpload) {
      if (isCancelled?.call() == true) break;
      final meta = fileMap[path];
      if (meta == null) continue;

      onProgress?.call(done, needsUpload.length, totalBytes, p.basename(path));

      bool ok = false;
      String? lastErr;

      for (int attempt = 0; attempt < 3 && !ok; attempt++) {
        try {
          final bytes = await File(path).readAsBytes();
          final localSha = sha256.convert(bytes).toString();

          final req = http.MultipartRequest(
              'POST', Uri.parse('$apiBase/api/v1/backup/upload'));
          req.headers[HttpHeaders.authorizationHeader] = 'Bearer $token';
          req.fields['device_id'] = deviceId;
          req.fields['file_path'] = path;
          req.fields['mtime'] = meta.mtime.toString();
          req.fields['sha256'] = localSha;
          req.files.add(http.MultipartFile.fromBytes(
            'file', bytes,
            filename: p.basename(path),
            contentType: MediaType('application', 'octet-stream'),
          ));

          final client = VaultManager.instance.makeClient();
          try {
            final streamed = await client
                .send(req)
                .timeout(const Duration(minutes: 10));
            final body = await streamed.stream
                .bytesToString()
                .timeout(const Duration(minutes: 2));

            if (streamed.statusCode == 200) {
              final serverSha =
                  (jsonDecode(body) as Map<String, dynamic>)['sha256']
                      as String? ??
                      '';
              if (serverSha.isNotEmpty && serverSha != localSha) {
                lastErr = 'sha256 mismatch (attempt ${attempt + 1})';
                await Future.delayed(const Duration(seconds: 2));
                continue;
              }
              ok = true;
              uploaded++;
              totalBytes += bytes.length;
            } else {
              lastErr = 'HTTP ${streamed.statusCode}: $body';
              await Future.delayed(const Duration(seconds: 2));
            }
          } finally {
            client.close();
          }
        } catch (e) {
          lastErr = e.toString();
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      if (!ok) {
        errors++;
        failedFiles.add('${p.basename(path)}: $lastErr');
      }
      done++;
    }

    final result = DesktopBackupResult(
      uploaded: uploaded,
      newFiles: newCount,
      changedFiles: changedCount,
      skipped: unchangedCount,
      errors: errors,
      totalBytes: totalBytes,
      failedFiles: failedFiles,
    );
    await _saveResult(result);
    return result;
  }
}

class _FileMeta {
  final String path;
  final int size;
  final int mtime;
  const _FileMeta({required this.path, required this.size, required this.mtime});
}
