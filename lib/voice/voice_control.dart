import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../i18n/i18n.dart';
import '../services/local_db_service.dart';
import 'voice_grammar.dart';

typedef VoiceHandler = FutureOr<String?> Function(VoiceIntent intent);

/// Настройки голосового управления (хранятся в `color_prefs`, как остальные переключатели).
class VoiceSettings {
  VoiceSettings._();

  static const _kOn = 'voice_control_on';
  static const _kAi = 'voice_control_ai';
  static const _kModel = 'voice_control_model';

  /// Включено ли голосовое управление (кнопка микрофона поверх приложения).
  static final ValueNotifier<bool> enabled = ValueNotifier(false);

  static String _read(LocalDbService db, String key) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [key]);
    return r.isEmpty ? '' : '${r.first['hex']}';
  }

  static void _write(LocalDbService db, String key, String v) => db.db.execute(
        'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
        [key, v],
      );

  /// База приложения (ставится при загрузке): нужна кнопке микрофона и ИИ-помощнику.
  static LocalDbService? db;

  static void load(LocalDbService database) {
    db = database;
    enabled.value = _read(database, _kOn) == '1';
  }

  static void setEnabled(LocalDbService db, bool v) {
    _write(db, _kOn, v ? '1' : '0');
    enabled.value = v;
  }

  /// ИИ-помощник для фраз, которые не разобрала грамматика (отдельная модель, выбирает только из списка действий).
  static bool aiOn(LocalDbService db) => _read(db, _kAi) == '1';
  static void setAiOn(LocalDbService db, bool v) =>
      _write(db, _kAi, v ? '1' : '0');

  /// Модель помощника: `auto` или id модели OpenRouter — отдельная от модели чата.
  static String model(LocalDbService db) {
    final v = _read(db, _kModel).trim();
    return v.isEmpty ? 'auto' : v;
  }

  static void setModel(LocalDbService db, String v) =>
      _write(db, _kModel, v.trim());
}

/// Голосовое управление: распознавание речи средствами самой системы телефона (бесплатно, у Android — встроенный
/// распознаватель Google, у iPhone — Siri/Speech), разбор по правилам и выполнение действия на текущем экране.
/// Экраны сами регистрируют, что они умеют (`register`), и снимают регистрацию при закрытии.
class VoiceControl {
  VoiceControl._();
  static final VoiceControl instance = VoiceControl._();

  final Map<VoiceAction, List<({Object owner, VoiceHandler fn})>> _handlers =
      {};

  /// Идёт прослушивание (кнопка микрофона мигает) и что уже услышано.
  final ValueNotifier<bool> listening = ValueNotifier(false);
  final ValueNotifier<String> heard = ValueNotifier('');

  final List<({Object owner, String mode})> _modes = [];

  /// Режим верхнего экрана (тренировка, переписка…): от него зависит, как понимаются фразы.
  String? get currentMode => _modes.isEmpty ? null : _modes.last.mode;

  void register(Object owner, Map<VoiceAction, VoiceHandler> handlers,
      {String? mode}) {
    unregister(owner);
    handlers
        .forEach((a, fn) => (_handlers[a] ??= []).add((owner: owner, fn: fn)));
    if (mode != null) _modes.add((owner: owner, mode: mode));
  }

  void unregister(Object owner) {
    _modes.removeWhere((m) => m.owner == owner);
    for (final l in _handlers.values) {
      l.removeWhere((h) => h.owner == owner);
    }
  }

  bool canDo(VoiceAction a) => (_handlers[a] ?? const []).isNotEmpty;

  /// Выполняет действие на самом верхнем (последнем зарегистрированном) экране. Возвращает текст для ответа.
  Future<String> execute(VoiceIntent intent) async {
    final l = _handlers[intent.action];
    if (l == null || l.isEmpty) return tr('Здесь эта команда недоступна');
    final r = await l.last.fn(intent);
    return r ?? tr('Готово');
  }

  final SpeechToText _stt = SpeechToText();
  bool _ready = false;

  static String _locale() => switch (I18n.code) {
        'en' => 'en_US',
        'de' => 'de_DE',
        'zh' => 'zh_CN',
        _ => 'ru_RU',
      };

  /// Слушает одну фразу. `null` — не получилось (нет доступа к микрофону, нет распознавателя, тишина).
  Future<String?> listenOnce(
      {Duration listenFor = const Duration(seconds: 8)}) async {
    if (listening.value) {
      await stop();
      return null;
    }
    try {
      if (!_ready) {
        _ready = await _stt.initialize(
            onError: (e) => debugPrint('STT: ${e.errorMsg}'));
      }
      if (!_ready) return null;
      // Несколько сеансов подряд: системное распознавание заканчивает сеанс на первой короткой паузе
      // («что» ... «можешь»). Ждём настоящую паузу — сеанс без новых слов — и только тогда отдаём фразу целиком.
      heard.value = '';
      listening.value = true;
      final parts = <String>[];
      final deadline = DateTime.now().add(listenFor + const Duration(seconds: 8));
      var firstSession = true;
      while (DateTime.now().isBefore(deadline)) {
        final text = await _session(firstSession ? listenFor : const Duration(seconds: 2), parts.join(' '));
        firstSession = false;
        if (!listening.value) break; // нажали ещё раз — остановили
        if (text == null || text.trim().isEmpty) break; // пауза: новых слов нет
        parts.add(text.trim());
        heard.value = parts.join(' ');
      }
      final all = parts.join(' ').trim();
      return all.isEmpty ? null : all;
    } catch (e) {
      debugPrint('Voice listen: $e');
      return null;
    } finally {
      listening.value = false;
      try {
        await _stt.stop();
      } catch (_) {}
    }
  }

  /// Один сеанс распознавания: итоговый текст или `null`, если ничего не сказано.
  Future<String?> _session(Duration listenFor, String before) async {
    final done = Completer<String?>();
    try {
      await _stt.listen(
        onResult: (SpeechRecognitionResult r) {
          heard.value = '$before ${r.recognizedWords}'.trim();
          if (r.finalResult && !done.isCompleted) done.complete(r.recognizedWords);
        },
        listenFor: listenFor,
        pauseFor: const Duration(seconds: 2),
        localeId: _locale(),
        listenOptions: SpeechListenOptions(partialResults: true, cancelOnError: true),
      );
      return await done.future.timeout(listenFor + const Duration(seconds: 3), onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  Future<void> stop() async {
    try {
      await _stt.stop();
    } catch (_) {}
    listening.value = false;
  }
}
