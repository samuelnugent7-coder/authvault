import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../config/app_config.dart';
import '../services/api_service.dart';
import '../services/vault_manager.dart';

/// Progress callback: (filesDone, filesTotal, bytesUploaded, currentFile)
typedef BackupProgressCallback = void Function(
    int done, int total, int bytesUploaded, String currentFile);

class BackupService {
  static const _storage = FlutterSecureStorage();
  static const _keyDeviceId = 'backup_device_id';
  static const _keyLastRun = 'backup_last_run';
  static const _keyLastStats = 'backup_last_stats';

  // Root directories to scan on Android internal + external storage.
  static const _scanRoots = [
    '/storage/emulated/0',
  ];

  // These paths are excluded (system noise).
  static const _excludePrefixes = [
    '/storage/emulated/0/Android/data',
    '/storage/emulated/0/Android/obb',
    '/storage/emulated/0/.Trash',
  ];

  static Future<String> getDeviceId() async {
    var id = await _storage.read(key: _keyDeviceId);
    if (id != null) return id;

    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final ai = await info.androidInfo;
      id = 'android-${ai.id}';
    } else if (Platform.isWindows) {
      final wi = await info.windowsInfo;
      id = 'windows-${wi.computerName}';
    } else {
      id = 'device-${DateTime.now().millisecondsSinceEpoch}';
    }
    await _storage.write(key: _keyDeviceId, value: id);
    return id!;
  }

  static Future<void> setLastRun(DateTime t) async {
    await _storage.write(key: _keyLastRun, value: t.toIso8601String());
  }

  static Future<DateTime?> getLastRun() async {
    final s = await _storage.read(key: _keyLastRun);
    if (s == null) return null;
    return DateTime.tryParse(s);
  }

  static Future<void> saveStats(Map<String, dynamic> stats) async {
    await _storage.write(key: _keyLastStats, value: jsonEncode(stats));
  }

  static Future<Map<String, dynamic>?> getLastStats() async {
    final s = await _storage.read(key: _keyLastStats);
    if (s == null) return null;
    return jsonDecode(s) as Map<String, dynamic>;
  }

  // ---- Permission request ----

  /// Checks whether sufficient storage permissions are granted.
  static Future<bool> hasPermissions() async {
    if (!Platform.isAndroid) return true;
    // MANAGE_EXTERNAL_STORAGE is the most permissive — grants full file access.
    if (await Permission.manageExternalStorage.isGranted) return true;
    final sdkInt = await _androidSdk();
    if (sdkInt >= 33) {
      // Granular media permissions allow scanning media folders.
      return await Permission.photos.isGranted ||
          await Permission.videos.isGranted ||
          await Permission.audio.isGranted;
    }
    return await Permission.storage.isGranted;
  }

  /// Returns `true` if granted immediately.
  /// Returns `false` if the user was sent to the Special App Access settings
  /// screen — caller should observe app resume and call [hasPermissions] again.
  static Future<bool> requestPermissions() async {
    if (!Platform.isAndroid) return true;

    final sdkInt = await _androidSdk();

    // Try ordinary permissions first (these show inline dialogs).
    if (sdkInt >= 33) {
      await [Permission.photos, Permission.videos, Permission.audio].request();
    } else {
      await Permission.storage.request();
    }

    // Already have all-files access? Done.
    if (await Permission.manageExternalStorage.isGranted) return true;

    // MANAGE_EXTERNAL_STORAGE requires a special settings screen on Android 11+.
    // Calling .request() opens it but returns immediately — the caller must
    // re-check when the app resumes (BackupScreen handles this via lifecycle).
    if (sdkInt >= 30) {
      await Permission.manageExternalStorage.request();
      // Give it a brief moment in case the system grants it synchronously on
      // some ROMs, then return current status.
      await Future.delayed(const Duration(milliseconds: 500));
      return await Permission.manageExternalStorage.isGranted;
    }

    return await Permission.storage.isGranted ||
        await Permission.manageExternalStorage.isGranted;
  }

  // ---- Core backup logic ----

  /// Runs a full incremental backup. Designed to be called both from the
  /// foreground UI (with progress callback) and from WorkManager background tasks.
  static Future<BackupResult> runBackup({
    BackupProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    final token = await AppConfig.getToken();
    if (token == null) {
      return BackupResult.error('Not authenticated — unlock the app first');
    }

    // Primary API for check/upload; uses the backup address when configured.
    final apiBase = VaultManager.instance.getBackupApiBase();
    final deviceId = await getDeviceId();

    // 1. Collect all files
    onProgress?.call(0, 0, 0, 'Scanning files…');
    final List<_FileMeta> allFiles;
    try {
      allFiles = await _collectFiles();
    } on BackupScanException catch (e) {
      return BackupResult.error('Scan failed: ${e.message}\n\nMake sure \'All Files Access\' is granted for AuthVault in Settings.');
    } catch (e) {
      return BackupResult.error('Scan error: $e');
    }
    if (allFiles.isEmpty) {
      return BackupResult.error('No files found in storage. Make sure \'All Files Access\' is granted in Settings > Apps > AuthVault > Permissions.');
    }
    onProgress?.call(0, allFiles.length, 0, 'Found ${allFiles.length} files — checking server…');

    // 2. Ask server which files need uploading (size/mtime comparison, no sha256 yet).
    //    Send in batches of 500 to avoid giant request bodies.
    onProgress?.call(0, allFiles.length, 0, 'Checking against server…');
    const int _checkBatchSize = 500;
    final needsUpload = <String>[];
    int checkNewCount = 0;
    int checkChangedCount = 0;
    int checkUnchangedCount = 0;

    for (int batchStart = 0; batchStart < allFiles.length; batchStart += _checkBatchSize) {
      final batchEnd = (batchStart + _checkBatchSize).clamp(0, allFiles.length);
      final batch = allFiles.sublist(batchStart, batchEnd);

      final checkItems = batch.map((f) => {
            'path': f.path,
            'size': f.size,
            'mtime': f.mtime,
            'sha256': '', // omit sha256 in check to avoid hashing everything
          }).toList();

      final checkBody = jsonEncode({'device_id': deviceId, 'files': checkItems});
      final checkClient = VaultManager.instance.makeClient();
      final http.Response checkRes;
      try {
        checkRes = await checkClient.post(
          Uri.parse('$apiBase/api/v1/backup/check'),
          headers: {
            HttpHeaders.authorizationHeader: 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: checkBody,
        ).timeout(const Duration(seconds: 60));
      } finally {
        checkClient.close();
      }
      if (checkRes.statusCode != 200) {
        return BackupResult.error('Check failed: ${checkRes.body}');
      }
      final checkData = jsonDecode(checkRes.body) as Map<String, dynamic>;
      needsUpload.addAll(List<String>.from(checkData['needs_upload'] as List));
      checkNewCount += (checkData['new_count'] as int?) ?? 0;
      checkChangedCount += (checkData['changed_count'] as int?) ?? 0;
      checkUnchangedCount += (checkData['unchanged_count'] as int?) ?? 0;
    }

    if (needsUpload.isEmpty) {
      await setLastRun(DateTime.now());
      return BackupResult(
        uploaded: 0,
        newFiles: checkNewCount,
        changedFiles: checkChangedCount,
        skipped: checkUnchangedCount,
        errors: 0,
        totalBytes: 0,
      );
    }

    // Build quick lookup
    final fileMap = {for (final f in allFiles) f.path: f};

    // 3. Upload each file that needs it
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

      bool fileOk = false;
      String? lastErr;

      // Retry up to 3 times per file.
      for (int attempt = 0; attempt < 3 && !fileOk; attempt++) {
        try {
          // Read fresh bytes on every attempt in case a previous partial read
          // produced a bad buffer.
          final bytes = await File(path).readAsBytes();
          final localSha = sha256.convert(bytes).toString();

          final req = http.MultipartRequest(
            'POST',
            Uri.parse('$apiBase/api/v1/backup/upload'),
          );
          req.headers[HttpHeaders.authorizationHeader] = 'Bearer $token';
          req.fields['device_id'] = deviceId;
          req.fields['file_path'] = path;
          req.fields['mtime'] = meta.mtime.toString();
          req.fields['sha256'] = localSha;
          req.files.add(http.MultipartFile.fromBytes(
            'file',
            bytes,
            filename: p.basename(path),
            contentType: MediaType('application', 'octet-stream'),
          ));

          // Use a vault-aware client (supports self-signed HTTPS) with a
          // per-file timeout so large or slow files don't hang indefinitely.
          final client = VaultManager.instance.makeClient();
          try {
            final streamedRes = await client
                .send(req)
                .timeout(const Duration(minutes: 10));
            final resBody = await streamedRes.stream
                .bytesToString()
                .timeout(const Duration(minutes: 2));

            if (streamedRes.statusCode == 200) {
              final serverJson = jsonDecode(resBody) as Map<String, dynamic>;
              final serverSha = serverJson['sha256'] as String? ?? '';
              if (serverSha.isNotEmpty && serverSha != localSha) {
                lastErr = 'sha256 mismatch after upload (attempt ${attempt + 1})';
                await Future.delayed(const Duration(seconds: 2));
                continue;
              }
              fileOk = true;
              uploaded++;
              totalBytes += bytes.length;
            } else {
              lastErr = 'HTTP ${streamedRes.statusCode}: $resBody';
              await Future.delayed(const Duration(seconds: 2));
            }
          } finally {
            client.close();
          }
        } catch (e) {
          lastErr = e.toString();
          await Future.delayed(const Duration(seconds: 1));
        }
      }

      if (!fileOk) {
        errors++;
        failedFiles.add('${p.basename(path)}: $lastErr');
      }
      done++;
    }

    await setLastRun(DateTime.now());
    final result = BackupResult(
      uploaded: uploaded,
      newFiles: checkNewCount,
      changedFiles: checkChangedCount,
      skipped: checkUnchangedCount,
      errors: errors,
      totalBytes: totalBytes,
      failedFiles: failedFiles,
    );
    await saveStats(result.toJson());
    return result;
  }

  // ---- File collection ----

  static Future<List<_FileMeta>> _collectFiles() async {
    final result = <_FileMeta>[];
    final errors = <String>[];
    // Track visited real paths to prevent symlink cycles.
    final visited = <String>{};

    for (final root in _scanRoots) {
      final dir = Directory(root);
      if (!await dir.exists()) {
        errors.add('Root not found: $root');
        continue;
      }
      await _walkDir(dir, result, errors, visited);
    }

    if (result.isEmpty && errors.isNotEmpty) {
      throw BackupScanException(errors.join('\n'));
    }

    return result;
  }

  /// Manual recursive DFS with symlink following and cycle detection.
  /// A permission error on any single directory does not abort the entire scan.
  static Future<void> _walkDir(
      Directory dir,
      List<_FileMeta> result,
      List<String> errors,
      Set<String> visited) async {
    // Resolve the real path to detect cycles from symlinks.
    String realPath;
    try {
      realPath = await dir.resolveSymbolicLinks();
    } catch (_) {
      realPath = dir.path;
    }
    if (!visited.add(realPath)) return; // already visited — cycle detected

    List<FileSystemEntity> entries;
    try {
      // followLinks: true so symlinked subdirectories (common on Android) are traversed.
      entries = await dir.list(recursive: false, followLinks: true).toList();
    } catch (e) {
      errors.add('Cannot list ${dir.path}: $e');
      return;
    }

    for (final entity in entries) {
      final path = entity.path;

      if (_excludePrefixes.any((ex) => path.startsWith(ex))) continue;
      if (p.basename(path).startsWith('.')) continue;

      if (entity is Directory || (entity is Link)) {
        // For links, check if they point to a directory.
        final target = entity is Link ? Directory(path) : entity as Directory;
        await _walkDir(target, result, errors, visited);
      } else if (entity is File) {
        try {
          final stat = await entity.stat();
          if (stat.size >= 0) {
            result.add(_FileMeta(
              path: path,
              size: stat.size,
              mtime: stat.modified.millisecondsSinceEpoch ~/ 1000,
            ));
          }
        } catch (_) {
          // Per-file access denied — skip silently.
        }
      }
    }
  }

  static Future<int> _androidSdk() async {
    if (!Platform.isAndroid) return 0;
    final info = DeviceInfoPlugin();
    final ai = await info.androidInfo;
    return ai.version.sdkInt;
  }
}

class _FileMeta {
  final String path;
  final int size;
  final int mtime;
  const _FileMeta({required this.path, required this.size, required this.mtime});
}

class BackupScanException implements Exception {
  final String message;
  const BackupScanException(this.message);
  @override
  String toString() => 'BackupScanException: $message';
}

class BackupResult {
  final int uploaded;
  final int newFiles;
  final int changedFiles;
  final int skipped;
  final int errors;
  final int totalBytes;
  final String? errorMessage;
  final List<String> failedFiles;

  const BackupResult({
    required this.uploaded,
    this.newFiles = 0,
    this.changedFiles = 0,
    required this.skipped,
    required this.errors,
    required this.totalBytes,
    this.errorMessage,
    this.failedFiles = const [],
  });

  factory BackupResult.error(String msg) => BackupResult(
        uploaded: 0,
        skipped: 0,
        errors: 1,
        totalBytes: 0,
        errorMessage: msg,
        failedFiles: const [],
      );

  bool get isError => errorMessage != null;

  Map<String, dynamic> toJson() => {
        'uploaded': uploaded,
        'new_files': newFiles,
        'changed_files': changedFiles,
        'skipped': skipped,
        'errors': errors,
        'total_bytes': totalBytes,
        'ran_at': DateTime.now().toIso8601String(),
      };

  String get summary {
    if (isError) return 'Error: $errorMessage';
    final parts = <String>[];
    if (newFiles > 0) parts.add('$newFiles new');
    if (changedFiles > 0) parts.add('$changedFiles changed');
    if (skipped > 0) parts.add('$skipped unchanged');
    if (errors > 0) parts.add('$errors errors');
    var s = parts.isEmpty ? 'Nothing to upload' : parts.join(', ');
    if (totalBytes > 0) s += ' — ${_humanBytes(totalBytes)} uploaded';
    if (failedFiles.isNotEmpty) {
      s += '\nFailed files:\n${failedFiles.take(20).join("\n")}';
      if (failedFiles.length > 20) s += '\n… and ${failedFiles.length - 20} more';
    }
    return s;
  }

  static String _humanBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
