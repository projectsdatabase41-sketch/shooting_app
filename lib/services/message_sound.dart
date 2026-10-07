import 'package:audioplayers/audioplayers.dart';

/// Звук нового сообщения в открытом чате: можно выключить, выбрать мелодию и
/// громкость (Настройки мессенджера → Уведомления). Не чаще раза в секунду;
/// любые сбои звука тихо игнорируются — чат от них не зависит.
class MessageSound {
  MessageSound._();

  /// (файл без .wav, название — ключ перевода)
  static const List<(String, String)> melodies = [
    ('message', /*tr*/ 'Пузырь'),
    ('bell', /*tr*/ 'Колокольчик'),
    ('drop', /*tr*/ 'Капля'),
    ('tick', /*tr*/ 'Тик'),
    ('chime', /*tr*/ 'Перезвон'),
    ('gong', /*tr*/ 'Гонг'),
  ];

  static final AudioPlayer _player = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  static bool _enabled = true;
  static String _name = 'message';
  static double _volume = 0.6;

  static void apply({required bool enabled, required String name, required double volume}) {
    _enabled = enabled;
    _name = name;
    _volume = volume;
  }

  /// Звук нового сообщения (с учётом настроек).
  static Future<void> play() async {
    if (!_enabled) return;
    final now = DateTime.now();
    if (now.difference(_last) < const Duration(seconds: 1)) return;
    _last = now;
    await _play(_name, _volume);
  }

  /// Прослушать мелодию в настройках (всегда, даже если звук выключен).
  static Future<void> preview(String name, double volume) => _play(name, volume);

  static Future<void> _play(String name, double volume) async {
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/$name.wav'), volume: volume);
    } catch (_) {}
  }
}
