import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import '../models/share_grant.dart';

/// Токены доступа тренеров (раздел 8/9 ТЗ, часть C.5 логики-спека).
///
/// Локальная реализация (для работы без реального Supabase — раздел 12
/// ТЗ): токен генерируется на устройстве, хранится хеш. При подключении
/// реального бэкенда вызовы делегируются в RPC `create_share_token` /
/// `revoke_share_token` (sql/schema.sql) — контракт методов уже совпадает.
class ShareTokenService {
  final List<ShareGrant> Function() readGrants;
  final Future<void> Function(ShareGrant grant) persistGrant;
  final Future<void> Function(String id, DateTime revokedAt) persistRevoke;

  ShareTokenService({
    required this.readGrants,
    required this.persistGrant,
    required this.persistRevoke,
  });

  static String _newToken() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(24, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes);
  }

  static String hashToken(String token) {
    return sha256.convert(utf8.encode(token)).toString();
  }

  /// Возвращает токен ОДИН РАЗ клиенту — в базе сохраняется только хеш,
  /// исходный токен восстановить нельзя (C.5).
  Future<String> createToken({String athleteLabel = ''}) async {
    final token = _newToken();
    final grant = ShareGrant(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      tokenHash: hashToken(token),
      athleteLabel: athleteLabel,
      createdAt: DateTime.now(),
    );
    await persistGrant(grant);
    return token;
  }

  Future<void> revoke(String grantId) async {
    await persistRevoke(grantId, DateTime.now());
  }

  /// Список токенов у спортсмена = `share_grants where revoked_at is
  /// null` — отозванные не запрашиваются для отображения, не
  /// фильтруются на клиенте (C.5).
  List<ShareGrant> activeGrants() {
    return readGrants().where((g) => g.isActive).toList();
  }
}
