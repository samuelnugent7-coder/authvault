class SafeItem {
  final int? id;
  final int? recordId;
  final String name;
  final String content;

  const SafeItem({this.id, this.recordId, required this.name, required this.content});

  factory SafeItem.fromJson(Map<String, dynamic> j) => SafeItem(
        id: j['id'] as int?,
        recordId: j['record_id'] as int?,
        name: j['name'] as String? ?? '',
        content: j['content'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        if (recordId != null) 'record_id': recordId,
        'name': name,
        'content': content,
      };
}

class SafeRecord {
  final int? id;
  final int folderId;
  final String name;
  final String login;
  final String password;
  final List<SafeItem> items;

  const SafeRecord({
    this.id,
    required this.folderId,
    required this.name,
    this.login = '',
    this.password = '',
    this.items = const [],
  });

  factory SafeRecord.fromJson(Map<String, dynamic> j) => SafeRecord(
        id: j['id'] as int?,
        folderId: j['folder_id'] as int? ?? 0,
        name: j['name'] as String? ?? '',
        login: j['login'] as String? ?? '',
        password: j['password'] as String? ?? '',
        items: (j['items'] as List<dynamic>?)
                ?.map((e) => SafeItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'folder_id': folderId,
        'name': name,
        'login': login,
        'password': password,
        'items': items.map((i) => i.toJson()).toList(),
      };
}

class SafeFolder {
  final int? id;
  final String name;
  final int? parentId;
  final List<SafeFolder> children;
  final List<SafeRecord> records;

  const SafeFolder({
    this.id,
    required this.name,
    this.parentId,
    this.children = const [],
    this.records = const [],
  });

  factory SafeFolder.fromJson(Map<String, dynamic> j) => SafeFolder(
        id: j['id'] as int?,
        name: j['name'] as String? ?? '',
        parentId: j['parent_id'] as int?,
        children: (j['children'] as List<dynamic>?)
                ?.map((e) => SafeFolder.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        records: (j['records'] as List<dynamic>?)
                ?.map((e) => SafeRecord.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'name': name,
        if (parentId != null) 'parent_id': parentId,
        'children': children.map((c) => c.toJson()).toList(),
        'records': records.map((r) => r.toJson()).toList(),
      };
}
