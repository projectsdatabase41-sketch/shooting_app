import 'dart:convert';

import 'package:http/http.dart' as http;

import '../services/chat_auth_service.dart';
import 'finals_net.dart';

/// Роль в совместном финале.
enum FinalsRole { athlete, coach, helper }

/// Участник сессии (приглашение или принятое участие).
class FinalsMember {
  final String sessionId;
  final String userId;
  final FinalsRole role;
  final String? targetId; // за кого вводит помощник / какой участник финала спортсмен
  final String name;
  final String status; // invited | accepted | declined
  const FinalsMember(this.sessionId, this.userId, this.role, this.targetId, this.name, this.status);

  factory FinalsMember.fromJson(Map<String, dynamic> j) => FinalsMember(
        '${j['session_id']}',
        '${j['user_id']}',
        FinalsRole.values.firstWhere((r) => r.name == j['role'], orElse: () => FinalsRole.athlete),
        j['target_id'] as String?,
        '${j['name'] ?? ''}',
        '${j['status']}',
      );
}

/// Сессии совместных финалов в публичной базе мессенджера (sql/finals-sessions.sql).
/// Все методы возвращают `null`/пустой список при любой ошибке сети — экран
/// сам решает, что показать.
class FinalsSessionService {
  final ChatAuthService auth;
  FinalsSessionService(this.auth);

  http.Client Function() clientFactory = http.Client.new;

  Future<Map<String, String>?> _headers({bool returnRows = false}) async {
    if (!auth.isSignedIn) return null;
    final token = await auth.ensureFreshToken();
    if (token == null) return null;
    return {
      'apikey': auth.anonKey,
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
      'Prefer': returnRows ? 'return=representation' : 'return=minimal',
    };
  }

  Future<dynamic> _call(String method, String path, {Object? body, bool returnRows = false}) async {
    final h = await _headers(returnRows: returnRows);
    if (h == null) return null;
    final client = clientFactory();
    try {
      final uri = Uri.parse('${auth.url}/rest/v1/$path');
      final req = switch (method) {
        'GET' => client.get(uri, headers: h),
        'POST' => client.post(uri, headers: h, body: jsonEncode(body)),
        'PATCH' => client.patch(uri, headers: h, body: jsonEncode(body)),
        _ => throw ArgumentError(method),
      };
      final res = await req.timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) return null;
      if (res.body.isEmpty) return const [];
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Создаёт сессию; возвращает её id или `null`.
  Future<String?> create(String formatId) async {
    final r = await _call('POST', 'finals_sessions', body: {'format_id': formatId}, returnRows: true);
    if (r is List && r.isNotEmpty) return '${(r.first as Map)['id']}';
    return null;
  }

  Future<bool> invite(String sessionId, {required String userId, required FinalsRole role, String? targetId, String name = ''}) async {
    final r = await _call('POST', 'finals_session_members', body: {
      'session_id': sessionId,
      'user_id': userId,
      'role': role.name,
      'target_id': targetId,
      'name': name,
    });
    return r != null;
  }

  Future<List<FinalsMember>> members(String sessionId) async {
    final r = await _call('GET', 'finals_session_members?session_id=eq.$sessionId');
    return r is List ? [for (final j in r.cast<Map<String, dynamic>>()) FinalsMember.fromJson(j)] : const [];
  }

  /// Мои приглашения и принятые участия в ещё идущих финалах.
  Future<List<FinalsMember>> myInvitations() async {
    final r = await _call('GET',
        'finals_session_members?user_id=eq.${auth.userId}&status=in.(invited,accepted)&select=*,finals_sessions!inner(ended_at)&finals_sessions.ended_at=is.null');
    return r is List ? [for (final j in r.cast<Map<String, dynamic>>()) FinalsMember.fromJson(j)] : const [];
  }

  /// Принять или отклонить приглашение.
  Future<bool> answer(FinalsMember m, {required bool accept}) async {
    final r = await _call(
      'PATCH',
      'finals_session_members?session_id=eq.${m.sessionId}&user_id=eq.${auth.userId}&role=eq.${m.role.name}',
      body: {'status': accept ? 'accepted' : 'declined'},
    );
    return r != null;
  }

  /// Хозяин завершает сессию.
  Future<bool> end(String sessionId) async {
    final r = await _call('PATCH', 'finals_sessions?id=eq.$sessionId', body: {'ended_at': DateTime.now().toUtc().toIso8601String()});
    return r != null;
  }

  /// Канал реального времени сессии.
  FinalsChannel channel(String sessionId) => RealtimeFinalsChannel(
        baseUrl: auth.url,
        anonKey: auth.anonKey,
        sessionId: sessionId,
        userId: auth.userId,
        token: auth.ensureFreshToken,
      );

  /// Права автора для [FinalsHost.allowed]: хозяин, тренер и помощники — за
  /// любого (за кого вводить, тренер говорит устно и может поменять в ходе
  /// финала); спортсмен — только за свой id участника финала.
  static Set<String>? scopeFor(String author, String hostId, List<FinalsMember> members) {
    if (author == hostId) return null;
    final mine = members.where((m) => m.userId == author && m.status == 'accepted').toList();
    if (mine.any((m) => m.role == FinalsRole.coach || m.role == FinalsRole.helper)) return null;
    return {for (final m in mine) if (m.targetId != null) m.targetId!};
  }

  /// Команды («Заряжай», «Старт», «Стоп», «Далее») подаёт хозяин или тренер.
  static bool canControl(String author, String hostId, List<FinalsMember> members) =>
      author == hostId || members.any((m) => m.userId == author && m.role == FinalsRole.coach && m.status == 'accepted');
}
