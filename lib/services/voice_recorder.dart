import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier, kIsWeb;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Готовая запись голоса: [path] — файл на диске (на вебе — адрес blob),
/// [seconds] — длительность.
class VoiceClip {
  final String path;
  final int seconds;

  /// Огибающая громкости: 48 символов 0–f (hex), по одному на столбик волны.
  final String wave;
  const VoiceClip(this.path, this.seconds, [this.wave = '']);

  /// Байты записи (на вебе blob-адрес читается обычным запросом).
  Future<Uint8List> readBytes() async {
    if (kIsWeb) {
      return (await http.get(Uri.parse(path))).bodyBytes;
    }
    return File(path).readAsBytes();
  }
}

/// Запись голосовых сообщений (AAC/m4a: одинаково воспроизводится на Android,
/// iPhone и в браузерах, около 350 КБ в минуту). Длина не ограничена.
class VoiceRecorder {
  final AudioRecorder _rec = AudioRecorder();
  DateTime? _startedAt;
  Timer? _ampTimer;
  final List<double> _levels = []; // 0…1 на каждые ~100 мс

  /// Текущая громкость 0…1 — для живого индикатора во время записи.
  final level = ValueNotifier<double>(0);

  /// Сжимает записанные уровни в [bars] значений 0…15 (hex-строка).
  static String encodeWave(List<double> levels, {int bars = 48}) {
    if (levels.isEmpty) return '';
    final out = StringBuffer();
    for (var i = 0; i < bars; i++) {
      final a = (i * levels.length / bars).floor();
      var b = ((i + 1) * levels.length / bars).ceil();
      if (b <= a) b = a + 1;
      if (b > levels.length) b = levels.length;
      var mx = 0.0;
      for (var j = a; j < b; j++) {
        if (levels[j] > mx) mx = levels[j];
      }
      out.write((mx.clamp(0.0, 1.0) * 15).round().toRadixString(16));
    }
    return out.toString();
  }

  /// Высокое качество голосовых: 128 кбит/с, 44,1 кГц (обычное — 48 кбит/с, 22 кГц); файл примерно втрое тяжелее.
  static bool hd = false;

  bool get isRecording => _startedAt != null;

  /// Прошло секунд с начала записи.
  int get elapsedSeconds =>
      _startedAt == null ? 0 : DateTime.now().difference(_startedAt!).inSeconds;

  /// `false` — нет разрешения на микрофон.
  Future<bool> start() async {
    if (isRecording) return true;
    if (!await _rec.hasPermission()) return false;
    final encoder = await _rec.isEncoderSupported(AudioEncoder.aacLc)
        ? AudioEncoder.aacLc
        : AudioEncoder.opus;
    final ext = encoder == AudioEncoder.aacLc ? 'm4a' : 'webm';
    var path = 'voice.$ext';
    if (!kIsWeb) {
      final dir = await getTemporaryDirectory();
      path = p.join(dir.path, 'voice_${DateTime.now().millisecondsSinceEpoch}.$ext');
    }
    await _rec.start(
      RecordConfig(encoder: encoder, bitRate: hd ? 128000 : 48000, sampleRate: hd ? 44100 : 22050, numChannels: 1),
      path: path,
    );
    _startedAt = DateTime.now();
    _levels.clear();
    _ampTimer?.cancel();
    _ampTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      try {
        final amp = await _rec.getAmplitude();
        // Децибелы (≈ −60…0) → 0…1.
        final v = ((amp.current + 55) / 55).clamp(0.0, 1.0);
        _levels.add(v);
        level.value = v;
      } catch (_) {}
    });
    return true;
  }

  /// Остановить и получить запись; `null` — записи нет или она короче секунды.
  Future<VoiceClip?> stop() async {
    final started = _startedAt;
    if (started == null) return null;
    _startedAt = null;
    _ampTimer?.cancel();
    level.value = 0;
    final path = await _rec.stop();
    final seconds = DateTime.now().difference(started).inSeconds;
    if (path == null || seconds < 1) {
      if (path != null && !kIsWeb) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      return null;
    }
    return VoiceClip(path, seconds, encodeWave(_levels));
  }

  Future<void> cancel() async {
    _startedAt = null;
    _ampTimer?.cancel();
    level.value = 0;
    try {
      await _rec.cancel();
    } catch (_) {}
  }

  Future<void> dispose() async {
    _startedAt = null;
    try {
      await _rec.dispose();
    } catch (_) {}
  }
}
