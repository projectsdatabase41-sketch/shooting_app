import 'dart:convert';

import '../services/local_db_service.dart';

/// Сохранённый финал (запись хода: выстрелы, паузы, места).
class FinalRecord {
  final String id;
  final String formatId;
  final DateTime finishedAt;
  final int? userPlace;
  final double userTotal;
  final Map<String, dynamic> data;
  FinalRecord(this.id, this.formatId, this.finishedAt, this.userPlace, this.userTotal, this.data);
}

/// Хранилище финалов в локальной базе (обязательная запись хода финала).
class FinalsRepository {
  final LocalDbService db;
  FinalsRepository(this.db);

  /// Сохраняет итог ([record] — `FinalRunController.toRecord`).
  String save(Map<String, dynamic> record) {
    final id = 'final-${DateTime.now().microsecondsSinceEpoch}';
    final standings = (record['standings'] as List).cast<Map<String, dynamic>>();
    final me = standings.firstWhere((s) => s['user'] == true, orElse: () => const {});
    db.db.execute(
      'INSERT INTO finals_runs (id, format_id, finished_at, user_place, user_total, json) VALUES (?, ?, ?, ?, ?, ?)',
      [
        id,
        record['format'],
        record['finishedAt'],
        me['place'],
        (me['total'] as num?)?.toDouble() ?? 0,
        jsonEncode(record),
      ],
    );
    return id;
  }

  List<FinalRecord> list() => [
        for (final r in db.db.select('SELECT * FROM finals_runs ORDER BY finished_at DESC'))
          FinalRecord(
            r['id'] as String,
            r['format_id'] as String,
            DateTime.tryParse('${r['finished_at']}') ?? DateTime.now(),
            r['user_place'] as int?,
            (r['user_total'] as num?)?.toDouble() ?? 0,
            (jsonDecode(r['json'] as String) as Map).cast<String, dynamic>(),
          )
      ];
}
