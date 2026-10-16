import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:http/http.dart' as http;

import 'local_db_service.dart';
import 'supabase_auth_service.dart';

/// Синхронизация модуля «Заметки» с таблицей `notes` в своей базе Supabase.
///
/// Таблица `notes` общая: в ней лежит база знаний (источник `airtable` и др.),
/// поэтому приложение:
///  * пишет и читает ТОЛЬКО строки со своим `source = 'nexus_app'`, чужие не
///    трогает;
///  * заметку не удаляет, а переводит в `status = 'archived'`;
///  * эмбеддинги не пишет — их считает отдельный воркер, периодически читая
///    таблицу (ИИ эмбеддинги только читает).
/// Конфликты решаются «последняя правка побеждает» по `updated_at`.
class NotesSyncService {
  NotesSyncService(this.db, this.auth, {http.Client Function()? clientFactory})
      : clientFactory = clientFactory ?? http.Client.new;

  final LocalDbService db;
  final SupabaseAuthService auth;
  final http.Client Function() clientFactory;

  /// Растёт, когда синхронизация что-то изменила локально — экран заметок
  /// на это перечитывает список.
  static final changed = ValueNotifier<int>(0);
  static Timer? _timer;

  /// Отложенная синхронизация после правки заметки (раз в пару секунд, а не на
  /// каждую букву). Ничего не делает, если своя база не подключена.
  static void schedule(LocalDbService db) {
    final auth = SupabaseAuthService(db);
    if (!auth.hasBase) return;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 2), () async {
      final n = await NotesSyncService(db, auth).sync();
      if (n != null && n > 0) changed.value++;
    });
  }

  static const source = 'nexus_app';
  static const category = 'Заметки Nexus';

  /// Ключ приложения без входа: таблица `notes` открыта и для anon.
  Future<Map<String, String>?> _headers() async {
    if (!auth.hasBase) return null;
    final token = auth.isSignedIn ? await auth.ensureFreshToken() : null;
    return {
      'apikey': auth.anonKey,
      'Authorization': 'Bearer ${token ?? auth.anonKey}',
      'Content-Type': 'application/json',
    };
  }

  static String _summary(String content) {
    final t = content.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length <= 300 ? t : '${t.substring(0, 300)}…';
  }

  /// Один проход: отправить изменения, затем забрать чужие (с других устройств).
  /// Возвращает число изменённых записей или `null`, если база не подключена
  /// либо сеть недоступна.
  Future<int?> sync() async {
    final h = await _headers();
    if (h == null) return null;
    final client = clientFactory();
    try {
      final pushed = await _push(client, h);
      final pulled = await _pull(client, h);
      return pushed + pulled;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  Future<int> _push(http.Client client, Map<String, String> h) async {
    var changed = 0;
    final rows = db.db.select('SELECT * FROM coach_notes WHERE dirty = 1');
    for (final r in rows) {
      final id = r['id'] as String;
      final cloudId = r['cloud_id'] as String?;
      final deleted = (r['deleted'] as int? ?? 0) == 1;
      final now = DateTime.now().toUtc().toIso8601String();
      if (deleted) {
        if (cloudId != null) {
          final res = await client
              .patch(Uri.parse('${auth.url}/rest/v1/notes?id=eq.$cloudId&source=eq.$source'),
                  headers: h, body: jsonEncode({'status': 'archived', 'updated_at': now}))
              .timeout(const Duration(seconds: 20));
          if (res.statusCode >= 300) continue; // попробуем в следующий раз
        }
        db.db.execute('DELETE FROM coach_note_files WHERE note_id = ?', [id]);
        db.db.execute('DELETE FROM coach_notes WHERE id = ?', [id]);
        changed++;
        continue;
      }
      final content = r['content'] as String;
      final body = {
        'topic': r['topic'],
        'summary': _summary(content),
        'content': content,
        'status': 'active',
        'updated_at': r['updated_at'] ?? now,
      };
      if (cloudId == null) {
        final res = await client
            .post(Uri.parse('${auth.url}/rest/v1/notes'),
                headers: {...h, 'Prefer': 'return=representation'},
                body: jsonEncode({
                  ...body,
                  'category': category,
                  'source': source,
                  'tags': ['nexus'],
                  'metadata': {'local_id': id, if (r['chart_json'] != null) 'chart': jsonDecode(r['chart_json'] as String)},
                  'created_at': r['created_at'],
                }))
            .timeout(const Duration(seconds: 20));
        if (res.statusCode >= 300) continue;
        final decoded = jsonDecode(utf8.decode(res.bodyBytes));
        final newId = decoded is List && decoded.isNotEmpty ? '${(decoded.first as Map)['id']}' : null;
        if (newId == null) continue;
        db.db.execute('UPDATE coach_notes SET cloud_id = ?, dirty = 0 WHERE id = ?', [newId, id]);
      } else {
        final res = await client
            .patch(Uri.parse('${auth.url}/rest/v1/notes?id=eq.$cloudId&source=eq.$source'), headers: h, body: jsonEncode(body))
            .timeout(const Duration(seconds: 20));
        if (res.statusCode >= 300) continue;
        db.db.execute('UPDATE coach_notes SET dirty = 0 WHERE id = ?', [id]);
      }
      changed++;
    }
    return changed;
  }

  Future<int> _pull(http.Client client, Map<String, String> h) async {
    var changed = 0;
    final res = await client
        .get(
            Uri.parse('${auth.url}/rest/v1/notes?source=eq.$source&select=id,topic,content,summary,status,metadata,created_at,updated_at&limit=1000'),
            headers: h)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode >= 300) return 0;
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! List) return 0;
    for (final r in decoded.cast<Map<String, dynamic>>()) {
      final cloudId = '${r['id']}';
      final archived = r['status'] == 'archived';
      final local = db.db.select('SELECT id, dirty, updated_at FROM coach_notes WHERE cloud_id = ?', [cloudId]);
      if (local.isEmpty) {
        if (archived) continue;
        final id = '${(r['metadata'] is Map ? (r['metadata'] as Map)['local_id'] : null) ?? cloudId}';
        final chart = r['metadata'] is Map ? (r['metadata'] as Map)['chart'] : null;
        // Та же заметка могла уже прийти под своим локальным id.
        final exists = db.db.select('SELECT 1 FROM coach_notes WHERE id = ?', [id]);
        if (exists.isNotEmpty) {
          db.db.execute('UPDATE coach_notes SET cloud_id = ? WHERE id = ? AND cloud_id IS NULL', [cloudId, id]);
          continue;
        }
        db.db.execute(
          'INSERT INTO coach_notes (id, topic, content, chart_json, created_at, cloud_id, dirty, updated_at) VALUES (?, ?, ?, ?, ?, ?, 0, ?)',
          [
            id,
            '${r['topic'] ?? ''}',
            '${r['content'] ?? r['summary'] ?? ''}',
            chart == null ? null : jsonEncode(chart),
            '${r['created_at'] ?? DateTime.now().toIso8601String()}',
            cloudId,
            '${r['updated_at'] ?? ''}',
          ],
        );
        changed++;
        continue;
      }
      final row = local.first;
      if ((row['dirty'] as int? ?? 0) == 1) continue; // свои несинхронизированные правки главнее
      if (archived) {
        db.db.execute('DELETE FROM coach_note_files WHERE note_id = ?', [row['id']]);
        db.db.execute('DELETE FROM coach_notes WHERE id = ?', [row['id']]);
        changed++;
        continue;
      }
      final cloudUpd = DateTime.tryParse('${r['updated_at']}');
      final localUpd = DateTime.tryParse('${row['updated_at'] ?? ''}');
      if (cloudUpd != null && (localUpd == null || cloudUpd.isAfter(localUpd))) {
        db.db.execute(
          'UPDATE coach_notes SET topic = ?, content = ?, updated_at = ? WHERE id = ?',
          ['${r['topic'] ?? ''}', '${r['content'] ?? r['summary'] ?? ''}', '${r['updated_at']}', row['id']],
        );
        changed++;
      }
    }
    return changed;
  }
}
