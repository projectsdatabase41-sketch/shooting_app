import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../logic/text_search.dart';
import '../services/local_db_service.dart';

/// Короткая память локальной модели — таблица `local_ai_memory`, только на
/// устройстве. Два вида записей:
/// * `cache` — готовый ответ на ТОЧНО такой же запрос (второй раз модель
///   не считает — быстро и без нагрева телефона);
/// * `example` — удачный ответ облачного ИИ на служебную задачу. Локальной
///   модели подставляются 1–2 самых похожих примера — она учится на лету.
///
/// Объём ограничен [maxChars]: при переполнении стираются записи, к
/// которым дольше всего не обращались.
class LocalAiMemory {
  LocalAiMemory(this.db, {this.maxChars = 400000}) {
    // Таблица заводится здесь, а не в общей схеме: весь локальный ИИ живёт
    // в lib/local_ai/ и удаляется одной папкой.
    db.db.execute('''
CREATE TABLE IF NOT EXISTS local_ai_memory (
  key     TEXT PRIMARY KEY,
  kind    TEXT NOT NULL CHECK (kind IN ('cache','example')),
  task    TEXT NOT NULL,
  input   TEXT NOT NULL,
  output  TEXT NOT NULL,
  used_at TEXT NOT NULL
)''');
  }

  final LocalDbService db;
  final int maxChars;

  /// Один пример не больше этого — иначе раздует контекст маленькой модели.
  static const int exampleChars = 1200;

  static String _key(String kind, String task, String input) =>
      sha1.convert(utf8.encode('$kind|$task|$input')).toString();

  String? cached(String task, String input) {
    final key = _key('cache', task, input);
    final rows = db.db.select('SELECT output FROM local_ai_memory WHERE key = ?', [key]);
    if (rows.isEmpty) return null;
    _touch(key);
    return rows.first['output'] as String;
  }

  void remember(String kind, String task, String input, String output) {
    if (kind == 'example') {
      input = _clip(input);
      output = _clip(output);
    }
    db.db.execute(
      'INSERT INTO local_ai_memory (key, kind, task, input, output, used_at) VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(key) DO UPDATE SET output = excluded.output, used_at = excluded.used_at',
      [_key(kind, task, input), kind, task, input, output, DateTime.now().toIso8601String()],
    );
    _trim();
  }

  /// Похожие примеры для задачи: по ключевым словам запроса, а если
  /// совпадений нет — самые свежие.
  List<({String input, String output})> examples(String task, String query, {int limit = 2}) {
    final rows = db.db.select(
      "SELECT key, input, output FROM local_ai_memory WHERE kind = 'example' AND task = ? "
      'ORDER BY used_at DESC LIMIT 200',
      [task],
    );
    if (rows.isEmpty) return const [];
    final words = TextSearch.keywords(query, maxWords: 8);
    final scored = [for (final r in rows) (r, TextSearch.relevance('${r['input']}', words))]
      ..sort((a, b) => b.$2.compareTo(a.$2)); // стабильная сортировка: при равенстве — свежее
    final picked = scored.take(limit).map((e) => e.$1).toList();
    for (final r in picked) {
      _touch('${r['key']}');
    }
    return [for (final r in picked) (input: '${r['input']}', output: '${r['output']}')];
  }

  int get usedChars =>
      (db.db.select('SELECT COALESCE(SUM(LENGTH(input) + LENGTH(output)), 0) AS n FROM local_ai_memory').first['n']
          as int);

  int get count => db.db.select('SELECT COUNT(*) AS n FROM local_ai_memory').first['n'] as int;

  void clear() => db.db.execute('DELETE FROM local_ai_memory');

  void _touch(String key) => db.db.execute(
        'UPDATE local_ai_memory SET used_at = ? WHERE key = ?',
        [DateTime.now().toIso8601String(), key],
      );

  void _trim() {
    var over = usedChars - maxChars;
    if (over <= 0) return;
    final rows = db.db.select(
        'SELECT key, LENGTH(input) + LENGTH(output) AS n FROM local_ai_memory ORDER BY used_at ASC');
    final drop = <String>[];
    for (final r in rows) {
      if (over <= 0) break;
      drop.add('${r['key']}');
      over -= r['n'] as int;
    }
    for (final k in drop) {
      db.db.execute('DELETE FROM local_ai_memory WHERE key = ?', [k]);
    }
  }

  static String _clip(String s) => s.length <= exampleChars ? s : '${s.substring(0, exampleChars)}…';
}
