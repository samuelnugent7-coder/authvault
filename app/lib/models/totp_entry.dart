class TotpEntry {
  final int? id;
  final String name;
  final String issuer;
  final String secret;
  final int duration;
  final int length;
  final int hashAlgo; // 0=SHA1, 1=SHA256, 2=SHA512

  const TotpEntry({
    this.id,
    required this.name,
    required this.issuer,
    required this.secret,
    this.duration = 30,
    this.length = 6,
    this.hashAlgo = 0,
  });

  factory TotpEntry.fromJson(Map<String, dynamic> j) => TotpEntry(
        id: j['id'] as int?,
        name: j['name'] as String? ?? '',
        issuer: j['issuer'] as String? ?? '',
        secret: j['secret'] as String? ?? '',
        duration: j['duration'] as int? ?? 30,
        length: j['length'] as int? ?? 6,
        hashAlgo: j['hash_algo'] as int? ?? 0,
      );

  /// Import format matching Accounts.json
  factory TotpEntry.fromImportJson(Map<String, dynamic> j) => TotpEntry(
        name: j['Name'] as String? ?? '',
        issuer: j['Issuer'] as String? ?? '',
        secret: j['Secret'] as String? ?? '',
        duration: j['Duration'] as int? ?? 30,
        length: j['Length'] as int? ?? 6,
        hashAlgo: j['HashAlgo'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'name': name,
        'issuer': issuer,
        'secret': secret,
        'duration': duration,
        'length': length,
        'hash_algo': hashAlgo,
      };

  TotpEntry copyWith({
    int? id,
    String? name,
    String? issuer,
    String? secret,
    int? duration,
    int? length,
    int? hashAlgo,
  }) =>
      TotpEntry(
        id: id ?? this.id,
        name: name ?? this.name,
        issuer: issuer ?? this.issuer,
        secret: secret ?? this.secret,
        duration: duration ?? this.duration,
        length: length ?? this.length,
        hashAlgo: hashAlgo ?? this.hashAlgo,
      );
}
