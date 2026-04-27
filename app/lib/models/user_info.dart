/// Lightweight model returned by /api/v1/auth/login and /api/v1/auth/me
class UserInfo {
  final String username;
  final bool isAdmin;
  final UserPermissions perms;

  const UserInfo({
    required this.username,
    required this.isAdmin,
    required this.perms,
  });

  factory UserInfo.fromJson(Map<String, dynamic> j) => UserInfo(
        username: j['username'] as String? ?? '',
        isAdmin: j['is_admin'] as bool? ?? false,
        perms: UserPermissions.fromJson(
            (j['permissions'] as Map<String, dynamic>?) ?? {}),
      );

  Map<String, dynamic> toJson() => {
        'username': username,
        'is_admin': isAdmin,
        'permissions': perms.toJson(),
      };
}

class UserPermissions {
  final ResourcePerms totp;
  final ResourcePerms safe;
  final ResourcePerms backup;

  const UserPermissions({
    required this.totp,
    required this.safe,
    required this.backup,
  });

  factory UserPermissions.adminAll() => const UserPermissions(
        totp: ResourcePerms(read: true, write: true, delete: true),
        safe: ResourcePerms(read: true, write: true, delete: true),
        backup: ResourcePerms(read: true, write: true, delete: true),
      );

  factory UserPermissions.fromJson(Map<String, dynamic> j) => UserPermissions(
        totp: ResourcePerms.fromJson(
            (j['totp'] as Map<String, dynamic>?) ?? {}),
        safe: ResourcePerms.fromJson(
            (j['safe'] as Map<String, dynamic>?) ?? {}),
        backup: ResourcePerms.fromJson(
            (j['backup'] as Map<String, dynamic>?) ?? {}),
      );

  Map<String, dynamic> toJson() => {
        'totp': totp.toJson(),
        'safe': safe.toJson(),
        'backup': backup.toJson(),
      };
}

class ResourcePerms {
  final bool read;
  final bool write;
  final bool delete;

  const ResourcePerms({
    required this.read,
    required this.write,
    required this.delete,
  });

  factory ResourcePerms.fromJson(Map<String, dynamic> j) => ResourcePerms(
        read: j['read'] as bool? ?? false,
        write: j['write'] as bool? ?? false,
        delete: j['delete'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'read': read,
        'write': write,
        'delete': delete,
      };
}
