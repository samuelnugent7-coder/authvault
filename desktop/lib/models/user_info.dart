class ResourcePerms {
  final bool read;
  final bool write;
  final bool delete;
  final bool export;
  final bool import;
  const ResourcePerms({
    this.read = false,
    this.write = false,
    this.delete = false,
    this.export = false,
    this.import = false,
  });

  factory ResourcePerms.all() => const ResourcePerms(
      read: true, write: true, delete: true, export: true, import: true);

  factory ResourcePerms.fromJson(Map<String, dynamic> j) => ResourcePerms(
        read: j['read'] as bool? ?? false,
        write: j['write'] as bool? ?? false,
        delete: j['delete'] as bool? ?? false,
        export: j['export'] as bool? ?? false,
        import: j['import'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'read': read,
        'write': write,
        'delete': delete,
        'export': export,
        'import': import,
      };
}

class UserPermissions {
  final ResourcePerms totp;
  final ResourcePerms safe;
  final ResourcePerms backup;
  final ResourcePerms ssh;
  /// Per-folder read/write overrides. Key = folder ID as string.
  final Map<String, ResourcePerms> folderPerms;
  /// Per-TOTP-entry overrides. Key = TOTP ID as string.
  final Map<String, ResourcePerms> totpPerms;

  const UserPermissions({
    required this.totp,
    required this.safe,
    required this.backup,
    this.ssh = const ResourcePerms(),
    this.folderPerms = const {},
    this.totpPerms = const {},
  });

  factory UserPermissions.adminAll() => const UserPermissions(
        totp: ResourcePerms(read: true, write: true, delete: true, export: true, import: true),
        safe: ResourcePerms(read: true, write: true, delete: true, export: true, import: true),
        backup: ResourcePerms(read: true, write: true, delete: true),
        ssh: ResourcePerms(read: true, write: true, delete: true),
      );

  factory UserPermissions.fromJson(Map<String, dynamic> j) {
    Map<String, ResourcePerms> parseMap(dynamic raw) {
      if (raw == null) return {};
      final m = raw as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, ResourcePerms.fromJson(v as Map<String, dynamic>)));
    }

    return UserPermissions(
      totp: ResourcePerms.fromJson(
          (j['totp'] as Map<String, dynamic>?) ?? {}),
      safe: ResourcePerms.fromJson(
          (j['safe'] as Map<String, dynamic>?) ?? {}),
      backup: ResourcePerms.fromJson(
          (j['backup'] as Map<String, dynamic>?) ?? {}),
      ssh: ResourcePerms.fromJson(
          (j['ssh'] as Map<String, dynamic>?) ?? {}),
      folderPerms: parseMap(j['folder_perms']),
      totpPerms: parseMap(j['totp_perms']),
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'totp': totp.toJson(),
      'safe': safe.toJson(),
      'backup': backup.toJson(),
      'ssh': ssh.toJson(),
    };
    if (folderPerms.isNotEmpty) {
      m['folder_perms'] = folderPerms.map((k, v) => MapEntry(k, v.toJson()));
    }
    if (totpPerms.isNotEmpty) {
      m['totp_perms'] = totpPerms.map((k, v) => MapEntry(k, v.toJson()));
    }
    return m;
  }

  UserPermissions copyWith({
    ResourcePerms? totp,
    ResourcePerms? safe,
    ResourcePerms? backup,
    ResourcePerms? ssh,
    Map<String, ResourcePerms>? folderPerms,
    Map<String, ResourcePerms>? totpPerms,
  }) {
    return UserPermissions(
      totp: totp ?? this.totp,
      safe: safe ?? this.safe,
      backup: backup ?? this.backup,
      ssh: ssh ?? this.ssh,
      folderPerms: folderPerms ?? this.folderPerms,
      totpPerms: totpPerms ?? this.totpPerms,
    );
  }
}

class UserInfo {
  final String username;
  final bool isAdmin;
  final UserPermissions perms;
  const UserInfo(
      {required this.username, required this.isAdmin, required this.perms});

  factory UserInfo.fromJson(Map<String, dynamic> j) => UserInfo(
        username: j['username'] as String? ?? 'admin',
        isAdmin: j['is_admin'] as bool? ?? false,
        perms: UserPermissions.fromJson(
            (j['perms'] as Map<String, dynamic>?) ?? {}),
      );
}
