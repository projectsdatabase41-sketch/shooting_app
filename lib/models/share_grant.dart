/// Токен доступа тренера (раздел 8/9 ТЗ, часть C.5 логики-спека).
/// Хранится хеш токена, не сам токен — восстановить исходный токен на
/// сервере нельзя, только перевыпустить новый.
class ShareGrant {
  final String id;
  final String tokenHash;
  final String athleteLabel;
  final DateTime createdAt;
  final DateTime? revokedAt;

  /// Политика доступа тренера: 'basic' — тренировки, результаты, комментарии;
  /// 'extended' — плюс таблицы из [tables] (см. sql/share-policy.sql).
  final String policy;
  final List<String> tables;

  bool get isExtended => policy == 'extended';

  const ShareGrant({
    required this.id,
    required this.tokenHash,
    required this.athleteLabel,
    required this.createdAt,
    this.revokedAt,
    this.policy = 'basic',
    this.tables = const [],
  });

  bool get isActive => revokedAt == null;

  ShareGrant copyWith({
    String? id,
    String? tokenHash,
    String? athleteLabel,
    DateTime? createdAt,
    DateTime? revokedAt,
    String? policy,
    List<String>? tables,
  }) {
    return ShareGrant(
      id: id ?? this.id,
      tokenHash: tokenHash ?? this.tokenHash,
      athleteLabel: athleteLabel ?? this.athleteLabel,
      createdAt: createdAt ?? this.createdAt,
      revokedAt: revokedAt ?? this.revokedAt,
      policy: policy ?? this.policy,
      tables: tables ?? this.tables,
    );
  }

  factory ShareGrant.fromJson(Map<String, dynamic> json) => ShareGrant(
        id: json['id'] as String,
        tokenHash: json['token_hash'] as String,
        athleteLabel: json['athlete_label'] as String? ?? '',
        createdAt: DateTime.parse(json['created_at'] as String),
        revokedAt: json['revoked_at'] == null
            ? null
            : DateTime.parse(json['revoked_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'token_hash': tokenHash,
        'athlete_label': athleteLabel,
        'created_at': createdAt.toIso8601String(),
        'revoked_at': revokedAt?.toIso8601String(),
      };
}
