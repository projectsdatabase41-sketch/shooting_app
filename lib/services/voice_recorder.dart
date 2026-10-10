import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Готовая запись голоса: [path] — файл на диске (на вебе — адрес blob),
/// [seconds] — длительность.
class VoiceClip {
  final String path;
  final int seconds;
  const VoiceClip(this.path, this.seconds);

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
      RecordConfig(encoder: encoder, bitRate: 48000, sampleRate: 22050, numChannels: 1),
      path: path,
    );
    _startedAt = DateTime.now();
    return true;
  }

  /// Остановить и получить запись; `null` — записи нет или она короче секунды.
  Future<VoiceClip?> stop() async {
    final started = _startedAt;
    if (started == null) return null;
    _startedAt = null;
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
    return VoiceClip(path, seconds);
  }

  Future<void> cancel() async {
    _startedAt = null;
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
