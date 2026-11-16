import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Состоялось ли хоть раз снятие блокировки автовоспроизведения.
bool _unlocked = false;

/// Браузер блокирует автовоспроизведение удалённого звука до первого жеста
/// пользователя. flutter_webrtc сам держит <audio> в скрытом контейнере,
/// поэтому здесь только снимаем mute и повторяем play() — по жесту.
void nudgeRemoteAudio() {
  _unlocked = true;
  final nodes = web.document.querySelectorAll('audio');
  for (var i = 0; i < nodes.length; i++) {
    final el = nodes.item(i);
    if (el is web.HTMLAudioElement) {
      el.muted = false;
      el.play().toDart.ignore();
    }
  }
}

/// Разблокирован ли звук (для подсказки «нажмите на экран»).
bool get remoteAudioUnlocked => _unlocked;
