class VaultConfig {
  final String id;
  final String name;
  final String apiBase;
  final String? backupApiBase;
  final bool allowSelfSigned;

  const VaultConfig({
    required this.id,
    required this.name,
    required this.apiBase,
    this.backupApiBase,
    this.allowSelfSigned = false,
  });

  /// Returns the backup base URL, falling back to the main API base.
  String get effectiveBackupBase => backupApiBase ?? apiBase;

  VaultConfig copyWith({
    String? id,
    String? name,
    String? apiBase,
    String? backupApiBase,
    bool clearBackupApiBase = false,
    bool? allowSelfSigned,
  }) {
    return VaultConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      apiBase: apiBase ?? this.apiBase,
      backupApiBase:
          clearBackupApiBase ? null : (backupApiBase ?? this.backupApiBase),
      allowSelfSigned: allowSelfSigned ?? this.allowSelfSigned,
    );
  }

  factory VaultConfig.fromJson(Map<String, dynamic> j) => VaultConfig(
        id: j['id'] as String,
        name: j['name'] as String,
        apiBase: j['apiBase'] as String,
        backupApiBase: j['backupApiBase'] as String?,
        allowSelfSigned: (j['allowSelfSigned'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'apiBase': apiBase,
        if (backupApiBase != null) 'backupApiBase': backupApiBase,
        'allowSelfSigned': allowSelfSigned,
      };
}
