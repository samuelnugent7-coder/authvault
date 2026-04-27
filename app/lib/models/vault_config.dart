import 'package:uuid/uuid.dart';

/// Represents one server connection ("vault").
class VaultConfig {
  final String id;
  final String name;

  /// Primary API address – used for auth, TOTP, password safe.
  /// Can be http:// or https://. Self-signed certs are allowed when
  /// [allowSelfSigned] is true.
  final String apiBase;

  /// Optional separate address used only for backup uploads/downloads.
  /// Useful for LAN speed (192.168.x.x) while the primary uses Tailscale.
  /// If null, falls back to [apiBase].
  final String? backupApiBase;

  /// When true, TLS certificate errors (including self-signed certs) are
  /// ignored for this vault's connections.
  final bool allowSelfSigned;

  VaultConfig({
    String? id,
    required this.name,
    required this.apiBase,
    this.backupApiBase,
    this.allowSelfSigned = false,
  }) : id = id ?? const Uuid().v4();

  String get effectiveBackupBase => backupApiBase ?? apiBase;

  VaultConfig copyWith({
    String? name,
    String? apiBase,
    String? backupApiBase,
    bool clearBackupApiBase = false,
    bool? allowSelfSigned,
  }) =>
      VaultConfig(
        id: id,
        name: name ?? this.name,
        apiBase: apiBase ?? this.apiBase,
        backupApiBase: clearBackupApiBase ? null : (backupApiBase ?? this.backupApiBase),
        allowSelfSigned: allowSelfSigned ?? this.allowSelfSigned,
      );

  factory VaultConfig.fromJson(Map<String, dynamic> j) => VaultConfig(
        id: j['id'] as String,
        name: j['name'] as String,
        apiBase: j['api_base'] as String,
        backupApiBase: j['backup_api_base'] as String?,
        allowSelfSigned: (j['allow_self_signed'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'api_base': apiBase,
        if (backupApiBase != null) 'backup_api_base': backupApiBase,
        'allow_self_signed': allowSelfSigned,
      };
}
