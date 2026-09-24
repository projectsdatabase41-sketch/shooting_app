import 'dart:async';
import 'dart:convert';

/// Прямое соединение двух телефонов (WebRTC DataChannel) для уже открытого
/// диалога. Знакомство (offer/answer/ICE) идёт через тот же приватный
/// канал Realtime — см. `LiveChatSession`. Если соединение не поднялось
/// или оборвалось, `LiveChatSession` продолжает работать через Broadcast
/// и базу, поэтому здесь любая ошибка — просто «линка нет».
abstract class PeerLink {
  /// Канал данных открыт — можно слать.
  bool get isOpen;

  /// Строка от собеседника (JSON `{event, payload}`).
  set onMessage(void Function(String data)? cb);

  /// Изменилось состояние (открылся / закрылся).
  set onState(void Function()? cb);

  /// Исходящее сигнальное сообщение для собеседника (через Realtime).
  set onSignal(void Function(Map<String, dynamic> signal)? cb);

  /// Начать соединение; [initiator] создаёт offer.
  Future<void> start({required bool initiator});

  /// Сигнал от собеседника (offer / answer / ice).
  Future<void> handleSignal(Map<String, dynamic> signal);

  bool send(String data);
  void close();
}

/// Кодек кадра для канала данных — тот же формат, что у Broadcast.
String encodePeerFrame(String event, Map<String, dynamic> payload) => jsonEncode({'e': event, 'p': payload});

(String, Map<String, dynamic>)? decodePeerFrame(String raw) {
  try {
    final d = jsonDecode(raw);
    if (d is Map && d['e'] is String && d['p'] is Map) {
      return (d['e'] as String, Map<String, dynamic>.from(d['p'] as Map));
    }
  } catch (_) {}
  return null;
}
