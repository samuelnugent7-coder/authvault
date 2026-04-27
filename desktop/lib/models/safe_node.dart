class SafeFolder {
  final int? id;
  final String name;
  final List<SafeRecord> records;
  final List<SafeFolder> children;

  const SafeFolder({
    this.id,
    required this.name,
    this.records = const [],
    this.children = const [],
  });

  factory SafeFolder.fromJson(Map<String, dynamic> j) => SafeFolder(
        id: j['id'] as int?,
        name: j['name'] as String? ?? '',
        records: (j['records'] as List<dynamic>? ?? [])
            .map((r) => SafeRecord.fromJson(r as Map<String, dynamic>))
            .toList(),
        children: (j['children'] as List<dynamic>? ?? [])
            .map((c) => SafeFolder.fromJson(c as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'name': name,
        'records': records.map((r) => r.toJson()).toList(),
        'children': children.map((c) => c.toJson()).toList(),
      };

  /// Flatten this folder and all nested children into a single list.
  List<SafeFolder> get allFolders => [this, ...children.expand((c) => c.allFolders)];
}

class SafeRecord {
  final int? id;
  final int? folderId;
  final String title;
  final String username;
  final String password;
  final String url;
  final String notes;
  final List<SafeItem> items;

  const SafeRecord({
    this.id,
    this.folderId,
    required this.title,
    this.username = '',
    this.password = '',
    this.url = '',
    this.notes = '',
    this.items = const [],
  });

  factory SafeRecord.fromJson(Map<String, dynamic> j) => SafeRecord(
        id: j['id'] as int?,
        folderId: j['folder_id'] as int?,
        // API uses 'name' / 'login'; Dart model exposes 'title' / 'username'
        title: (j['name'] ?? j['title']) as String? ?? '',
        username: (j['login'] ?? j['username']) as String? ?? '',
        password: j['password'] as String? ?? '',
        url: j['url'] as String? ?? '',
        notes: j['notes'] as String? ?? '',
        items: (j['items'] as List<dynamic>? ?? [])
            .map((i) => SafeItem.fromJson(i as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        if (folderId != null) 'folder_id': folderId,
        'name': title,      // API field name
        'login': username,  // API field name
        'password': password,
        'url': url,
        'notes': notes,
        'items': items.map((i) => i.toJson()).toList(),
      };
}

class SafeItem {
  final int? id;
  final int? recordId;
  final String label;
  final String value;

  const SafeItem({this.id, this.recordId, required this.label, required this.value});

  factory SafeItem.fromJson(Map<String, dynamic> j) => SafeItem(
        id: j['id'] as int?,
        recordId: j['record_id'] as int?,
        // API uses 'name' / 'content'; Dart model exposes 'label' / 'value'
        label: (j['name'] ?? j['label']) as String? ?? '',
        value: (j['content'] ?? j['value']) as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        if (recordId != null) 'record_id': recordId,
        'name': label,      // API field name
        'content': value,   // API field name
      };
}
