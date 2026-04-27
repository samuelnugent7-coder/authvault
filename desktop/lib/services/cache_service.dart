import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:path_provider/path_provider.dart';

/// Singleton that stores encrypted JSON blobs on disk.
///
/// The AES-256-GCM key is derived from the vault JWT token (SHA-256 of the
/// token bytes) so the cached files are useless without a valid login.
///
/// File format: [12-byte GCM nonce][AES-GCM ciphertext+tag]
class CacheService {
  CacheService._();
  static final CacheService instance = CacheService._();

  Uint8List? _key; // 32-byte AES-256 key, set on login / startup
  bool get hasKey => _key != null;

  // ── Key management ────────────────────────────────────────────────────────

  void setKeyFromToken(String jwt) {
    _key = Uint8List.fromList(sha256.convert(utf8.encode(jwt)).bytes);
  }

  void clearKey() => _key = null;

  // ── Storage directory ─────────────────────────────────────────────────────

  Future<Directory> get _dir async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/authvault_cache');
    await dir.create(recursive: true);
    return dir;
  }

  // ── Read / Write ──────────────────────────────────────────────────────────

  Future<void> write(String filename, dynamic data) async {
    if (_key == null) return; // no key → silently skip
    try {
      final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(data)));
      final key = enc.Key(_key!);
      final iv = enc.IV.fromSecureRandom(12);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
      final encrypted = encrypter.encryptBytes(plaintext, iv: iv);

      // Write: [12-byte nonce][ciphertext+16-byte GCM tag]
      final out = BytesBuilder()
        ..add(iv.bytes)
        ..add(encrypted.bytes);

      final file = File('${(await _dir).path}/$filename');
      await file.writeAsBytes(out.toBytes(), flush: true);
    } catch (_) {
      // Cache write failure is non-fatal
    }
  }

  /// Returns the decoded JSON value, or null if the file is missing / invalid.
  Future<dynamic> read(String filename) async {
    if (_key == null) return null;
    try {
      final file = File('${(await _dir).path}/$filename');
      if (!await file.exists()) return null;

      final bytes = await file.readAsBytes();
      if (bytes.length < 28) return null; // 12 nonce + 16 tag minimum

      final iv = enc.IV(Uint8List.fromList(bytes.sublist(0, 12)));
      final ciphertext = enc.Encrypted(Uint8List.fromList(bytes.sublist(12)));

      final key = enc.Key(_key!);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
      final decrypted = encrypter.decryptBytes(ciphertext, iv: iv);

      return jsonDecode(utf8.decode(decrypted));
    } catch (_) {
      return null; // corrupt / wrong key → treat as cache miss
    }
  }

  Future<void> delete(String filename) async {
    try {
      final file = File('${(await _dir).path}/$filename');
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Returns true if there is at least one cache file on disk (key set from token).
  Future<bool> hasCachedData() async {
    if (!hasKey) return false;
    try {
      final dir = await _dir;
      if (!await dir.exists()) return false;
      return await dir.list().any((_) => true);
    } catch (_) {
      return false;
    }
  }

  /// Wipe all cached data and clear the in-memory key.
  Future<void> clearAll() async {
    clearKey();
    try {
      final dir = await _dir;
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}
