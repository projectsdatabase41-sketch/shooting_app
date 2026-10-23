import 'dart:convert';

import 'package:http/http.dart' as http;

import '../services/chat_auth_service.dart';
import '../services/chat_settings.dart';
import '../services/demo_mode.dart';

/// Строка табло публичных финалов.
class FinalsBoardRow {
  final String id;
  final String hostName;
  final String formatId;
  final String key;
  final String? url;
  final String? anonKey;
  final int maxSpectators;
  final String status; // preparing | live | finished
  final List<Map<String, dynamic>> top;
  final DateTime updatedAt;
  const FinalsBoardRow(this.id, this.hostName, this.formatId, this.key, this.url, this.anonKey, this.maxSpectators, this.status, this.top, this.updatedAt);

  factory FinalsBoardRow.fromJson(Map<String, dynamic> j) => FinalsBoardRow(
        '${j['id']}',
        '${j['host_name'] ?? ''}',
        '${j['format_id']}',
        '${j['key']}',
        j['url'] as String?,
        j['anon_key'] as String?,
        (j['max_spectators'] as num?)?.toInt() ?? 50,
        '${j['status']}',
        [for (final e in (j['top'] as List? ?? const [])) (e as Map).cast<String, dynamic>()],
        DateTime.tryParse('${j['updated_at']}') ?? DateTime.now(),
      );
}

/// Табло публичных финалов (sql/finals-board.sql, публичная база мессенджера).
/// Читать может любой, писать — ведущий после входа в мессенджер. Любая ошибка — молча (`null`/пусто):
/// табло не должно мешать финалу.
class FinalsBoardService {
  final ChatAuthService auth;
  FinalsBoardService(this.auth);

  http.Client Function() clientFactory = http.Client.new;

  Map<String, String> _anon() => {'apikey': ChatSettings.anonKey, 'Authorization': 'Bearer ${ChatSettings.anonKey}'};

  Future<List<FinalsBoardRow>> list() async {
    final client = clientFactory();
    try {
      final res = await client
          .get(Uri.parse('${ChatSettings.url}/rest/v1/finals_board?select=*&order=updated_at.desc&limit=50'), headers: _anon())
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) return const [];
      return [for (final j in (jsonDecode(utf8.decode(res.bodyBytes)) as List).cast<Map<String, dynamic>>()) FinalsBoardRow.fromJson(j)];
    } catch (_) {
      return const [];
    } finally {
      client.close();
    }
  }

  Future<Map<String, String>?> _authed({bool rows = false}) async {
    if (!auth.isSignedIn) return null;
    final t = await auth.ensureFreshToken();
    if (t == null) return null;
    return {
      'apikey': ChatSettings.anonKey,
      'Authorization': 'Bearer $t',
      'Content-Type': 'application/json',
      'Prefer': rows ? 'return=representation' : 'return=minimal',
    };
  }

  /// Выставляет финал на табло; возвращает id строки.
  Future<String?> create({
    required String hostName,
    required String formatId,
    required String key,
    String? url,
    String? anonKey,
    required int maxSpectators,
  }) async {
    final h = await _authed(rows: true);
    if (h == null) return null;
    final client = clientFactory();
    try {
      final res = await client
          .post(Uri.parse('${ChatSettings.url}/rest/v1/finals_board'),
              headers: h,
              body: jsonEncode({
                'host_name': hostName,
                'format_id': formatId,
                'key': key,
                if (url != null && anonKey != null) ...{'url': url, 'anon_key': anonKey},
                'max_spectators': maxSpectators,
              }))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) {
        DemoMode.sendError('FinalsBoard create', '${res.statusCode}: ${utf8.decode(res.bodyBytes)}');
        return null;
      }
      final r = jsonDecode(utf8.decode(res.bodyBytes));
      return r is List && r.isNotEmpty ? '${(r.first as Map)['id']}' : null;
    } catch (e) {
      DemoMode.sendError('FinalsBoard create', e);
      return null;
    } finally {
      client.close();
    }
  }

  /// Меняет статус (и обновляет метку времени — «жив»).
  Future<void> update(String id, {String? status, List<Map<String, dynamic>>? top}) async {
    final h = await _authed();
    if (h == null) return;
    final client = clientFactory();
    try {
      await client
          .patch(Uri.parse('${ChatSettings.url}/rest/v1/finals_board?id=eq.$id'),
              headers: h,
              body: jsonEncode({
                if (status != null) 'status': status,
                if (top != null) 'top': top,
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              }))
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      // табло не критично
    } finally {
      client.close();
    }
  }

  Future<void> remove(String id) async {
    final h = await _authed();
    if (h == null) return;
    final client = clientFactory();
    try {
      await client.delete(Uri.parse('${ChatSettings.url}/rest/v1/finals_board?id=eq.$id'), headers: h).timeout(const Duration(seconds: 15));
    } catch (_) {
      // табло не критично
    } finally {
      client.close();
    }
  }
}
