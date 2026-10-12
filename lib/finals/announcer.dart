import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Строка рейтинга для озвучки.
class AnnounceRow {
  final String name;
  final double total;
  final bool active;
  final bool isMe;
  const AnnounceRow(this.name, this.total, this.active, {this.isMe = false});
}

const _ordinals = ['Первый', 'Второй', 'Третий', 'Четвёртый', 'Пятый', 'Шестой', 'Седьмой', 'Восьмой'];

String _num(double v) => v.toStringAsFixed(1).replaceAll('.', ',');

/// Текст комментария диктора после «Стоп»: лидеры, выбывшие, место спортсмена.
/// [rows] — по убыванию места; [eliminated] — выбывшие после этого раунда.
String standingsSpeech(List<AnnounceRow> rows, {List<String> eliminated = const [], String? lead}) {
  final active = [for (final r in rows) if (r.active) r];
  final parts = <String>[];
  if (lead != null && lead.isNotEmpty) parts.add(lead);
  for (final n in eliminated) {
    parts.add('Выбывает $n.');
  }
  if (active.isNotEmpty) {
    parts.add('Лидирует ${active.first.name}, ${_num(active.first.total)}.');
    for (var i = 1; i < active.length && i < 3; i++) {
      parts.add('${_ordinals[i]} ${active[i].name}, ${_num(active[i].total)}.');
    }
    final me = active.indexWhere((r) => r.isMe);
    if (me >= 3) parts.add('Вы на ${me + 1}-м месте, ${_num(active[me].total)}.');
  }
  return parts.join(' ');
}

/// Следит за состоянием и выдаёт текст диктора по фронту «началась пауза
/// диктора» (после «Стоп»): учитывает, кто выбыл с прошлого раза.
class AnnounceTracker {
  bool _was = false;
  Set<String>? _prevActive;

  /// [rows] — таблица по местам; [announcing] — идёт комментарий диктора.
  /// Возвращает текст или `null`, если говорить нечего.
  String? update(List<AnnounceRow> rows, {required bool announcing}) {
    final active = {for (final r in rows) if (r.active) r.name};
    String? text;
    if (announcing && !_was) {
      final prev = _prevActive;
      final out = prev == null ? <String>[] : [for (final n in prev) if (!active.contains(n)) n];
      text = standingsSpeech(rows, eliminated: out);
      _prevActive = active;
    }
    _prevActive ??= active;
    _was = announcing;
    return text?.isEmpty == true ? null : text;
  }
}

/// Озвучка средствами телефона (без ИИ и сети). Любая ошибка — молча без звука.
class FinalsAnnouncer {
  FinalsAnnouncer._();
  static final FlutterTts _tts = FlutterTts();
  static bool _ready = false;

  static Future<void> speak(String text, {String language = 'ru-RU'}) async {
    if (text.trim().isEmpty) return;
    try {
      if (!_ready) {
        await _tts.setLanguage(language);
        await _tts.setSpeechRate(0.5);
        _ready = true;
      }
      await _tts.stop();
      await _tts.speak(text);
    } catch (e) {
      debugPrint('TTS недоступен: $e');
    }
  }

  static Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
