import 'dart:convert';

import 'package:http/http.dart' as http;

import '../services/chat_auth_service.dart';
import '../services/chat_settings.dart';
import '../services/demo_mode.dart';

/// Строка табло публичных финалов.
class FinalsBoardRow {
  final String id;
  final String hostName;
  final String region;
  final String formatId;
  final int maxSpectators;
  final String status; // preparing | live | finished
  final List<String> jury;
  final List<String> athletes;
  final List<Map<String, dynamic>> top;
  final DateTime updatedAt;
  const FinalsBoardRow(this.id, this.hostName, this.region, this.formatId, this.maxSpectators, this.status, this.jury, this.athletes, this.top, this.updatedAt);

  factory FinalsBoardRow.fromJson(Map<String, dynamic> j) => FinalsBoardRow(
        '${j['id']}',
        '${j['host_name'] ?? ''}',
        '${j['region'] ?? ''}',
        '${j['format_id']}',
        (j['max_spectators'] as num?)?.toInt() ?? 50,
        '${j['status']}',
        [for (final n in ((j['people'] as Map?)?['jury'] as List? ?? const [])) '$n'],
        [for (final n in ((j['people'] as Map?)?['athletes'] as List? ?? const [])) '$n'],
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
          .get(Uri.parse('${ChatSettings.url}/rest/v1/finals_board?select=id,host_name,region,format_id,max_spectators,status,people,top,updated_at&order=updated_at.desc&limit=50'), headers: _anon())
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

  /// Данные для входа зрителем (секретное имя канала и база) — только для идущего или готовящегося финала.
  /// На табло они не показываются и напрямую не читаются.
  Future<({String key, String? url, String? anonKey})?> join(String id) async {
    final client = clientFactory();
    try {
      final res = await client
          .post(Uri.parse('${ChatSettings.url}/rest/v1/rpc/finals_board_join'),
              headers: {..._anon(), 'Content-Type': 'application/json'}, body: jsonEncode({'p_id': id}))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) return null;
      final r = jsonDecode(utf8.decode(res.bodyBytes));
      if (r is! List || r.isEmpty) return null;
      final m = (r.first as Map).cast<String, dynamic>();
      return (key: '${m['key']}', url: m['url'] as String?, anonKey: m['anon_key'] as String?);
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Выставляет финал на табло; возвращает id строки.
  Future<String?> create({
    required String hostName,
    String region = '',
    Map<String, dynamic> people = const {},
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
          .post(Uri.parse('${ChatSettings.url}/rest/v1/finals_board?select=id'),
              headers: h,
              body: jsonEncode({
                'host_name': hostName,
                'region': region,
                'people': people,
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
  Future<void> update(String id, {String? status, List<Map<String, dynamic>>? top, Map<String, dynamic>? people}) async {
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
                if (people != null) 'people': people,
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
