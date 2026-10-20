import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../services/local_db_service.dart';
import 'voice_packs.dart';
import 'voice_texts.dart';

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
    parts.add('Выбывает ${VoiceTexts.spokenName(n)}.');
  }
  if (active.isNotEmpty) {
    parts.add('Лидирует ${VoiceTexts.spokenName(active.first.name)}, ${_num(active.first.total)}.');
    for (var i = 1; i < active.length && i < 3; i++) {
      parts.add('${_ordinals[i]} ${VoiceTexts.spokenName(active[i].name)}, ${_num(active[i].total)}.');
    }
    final me = active.indexWhere((r) => r.isMe);
    if (me >= 3) parts.add('${VoiceTexts.spokenName(active[me].name)}, ${me + 1}-е место, ${_num(active[me].total)}.');
  }
  return parts.join(' ');
}

/// Те же фразы, но как список записей для склейки: именная запись («Лидирует Иванов») + числа счёта.
/// `null` — фраза с произвольным вступлением ([lead]) собирается только голосом телефона.
List<String>? standingsRefs(List<AnnounceRow> rows, {List<String> eliminated = const [], String? lead}) {
  if (lead != null && lead.isNotEmpty) return null;
  final active = [for (final r in rows) if (r.active) r];
  final out = <String>[];
  for (final n in eliminated) {
    out.add(VoiceTexts.namedRef('out', VoiceTexts.spokenName(n)));
  }
  if (active.isNotEmpty) {
    out
      ..add(VoiceTexts.namedRef('leads', VoiceTexts.spokenName(active.first.name)))
      ..addAll(VoiceTexts.numberRefs(active.first.total));
    for (var i = 1; i < active.length && i < 3; i++) {
      out
        ..add(VoiceTexts.namedRef('p${i + 1}', VoiceTexts.spokenName(active[i].name)))
        ..addAll(VoiceTexts.numberRefs(active[i].total));
    }
    final me = active.indexWhere((r) => r.isMe);
    if (me >= 3 && me < 8) {
      out
        ..add(VoiceTexts.namedRef('pl${me + 1}', VoiceTexts.spokenName(active[me].name)))
        ..addAll(VoiceTexts.numberRefs(active[me].total));
    }
  }
  return out.isEmpty ? null : out;
}

/// Следит за состоянием и выдаёт текст диктора по фронту «началась пауза
/// диктора» (после «Стоп»): учитывает, кто выбыл с прошлого раза.
class AnnounceTracker {
  bool _was = false;
  Set<String>? _prevActive;

  /// Записи для склейки к последнему возвращённому тексту (см. [standingsRefs]).
  List<String>? lastRefs;

  /// [rows] — таблица по местам; [announcing] — идёт комментарий диктора.
  /// Возвращает текст или `null`, если говорить нечего.
  String? update(List<AnnounceRow> rows, {required bool announcing}) {
    final active = {for (final r in rows) if (r.active) r.name};
    String? text;
    if (announcing && !_was) {
      final prev = _prevActive;
      final out = prev == null ? <String>[] : [for (final n in prev) if (!active.contains(n)) n];
      text = standingsSpeech(rows, eliminated: out);
      lastRefs = standingsRefs(rows, eliminated: out);
      _prevActive = active;
    }
    _prevActive ??= active;
    _was = announcing;
    return text?.isEmpty == true ? null : text;
  }
}

/// Команды диктора по смене этапа: «Заряжай», «Старт», «Стоп», «Финал окончен».
/// [phase] — имя этапа (sighting/loading/shooting/grace/finished).
class PhaseAnnouncer {
  String? _last;
  bool _loadingCalled = false;

  /// Запись команды к последнему возвращённому тексту (`cmd_load`, `cmd_start`…).
  String? lastRef;

  String? update(String phase, {required int secondsLeft, required bool announcing}) {
    String? say;
    lastRef = null;
    if (phase == 'loading' && !announcing && !_loadingCalled && _last != null) {
      _loadingCalled = true;
      say = 'Заряжай.';
      lastRef = 'cmd_load';
    }
    if (phase != _last) {
      if (phase == 'shooting') {
        say = 'Старт.';
        lastRef = 'cmd_start';
      }
      if (phase == 'grace' || (phase == 'loading' && _last == 'shooting')) {
        say = 'Стоп.';
        lastRef = 'cmd_stop';
      }
      if (phase == 'finished') {
        say = 'Финал окончен.';
        lastRef = 'cmd_finished';
      }
      if (phase == 'loading') _loadingCalled = false;
      if (phase == 'sighting' && _last == null) {
        say = 'Пристрелка.';
        lastRef = 'cmd_sighting';
      }
      _last = phase;
    }
    return say;
  }
}

/// Озвучка средствами телефона (без ИИ и сети). Любая ошибка — молча без звука.
class FinalsAnnouncer {
  FinalsAnnouncer._();
  static final FlutterTts _tts = FlutterTts();
  static bool _ready = false;

  /// Произнести фразу: готовыми записями ИИ-озвучки ([refs], склейка), а если их нет — голосом
  /// телефона. [queue] — не обрывать то, что уже звучит.
  static Future<void> say(LocalDbService db, String text, {List<String>? refs, bool queue = true}) async {
    if (refs != null && refs.isNotEmpty) {
      try {
        if (await VoicePacks.play(db, refs, queue: queue)) return;
      } catch (_) {}
    }
    await speak(text, queue: queue);
  }

  /// [queue] — не обрывать то, что уже звучит (команда и следом рейтинг).
  static Future<void> speak(String text, {String language = 'ru-RU', bool queue = false}) async {
    if (text.trim().isEmpty) return;
    try {
      if (!_ready) {
        await _tts.setLanguage(language);
        await _tts.setSpeechRate(0.5);
        try {
          await _tts.setQueueMode(1); // новая фраза встаёт в очередь
        } catch (_) {}
        _ready = true;
      }
      if (!queue) await _tts.stop();
      await _tts.speak(text);
    } catch (e) {
      debugPrint('TTS недоступен: $e');
    }
  }

  static Future<void> stop() async {
    await VoicePacks.stop();
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
