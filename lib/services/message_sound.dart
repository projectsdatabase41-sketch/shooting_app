import 'package:audioplayers/audioplayers.dart';

/// Мягкий звук нового сообщения в открытом чате (системный «клик» на iPhone и
/// в вебе почти не слышен). Не чаще раза в секунду; любые сбои звука тихо
/// игнорируются — чат от них не зависит.
class MessageSound {
  MessageSound._();

  static final AudioPlayer _player = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<void> play() async {
    final now = DateTime.now();
    if (now.difference(_last) < const Duration(seconds: 1)) return;
    _last = now;
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/message.wav'), volume: 0.6);
    } catch (_) {}
  }
}
