import 'package:flutter/foundation.dart';

import 'chat_auth_service.dart';
import '../i18n/i18n.dart';

/// «В сети» у друзей (sql/chat-presence.sql). Раз в минуту, пока открыт
/// мессенджер, отмечаемся на сервере и забираем время появления друзей.
class ChatPresence {
  static final seen = ValueNotifier<Map<String, DateTime>>({});
  static DateTime _last = DateTime(0);

  static Future<void> tick(ChatAuthService auth) async {
    if (DateTime.now().difference(_last) < const Duration(seconds: 60)) return;
    _last = DateTime.now();
    final fresh = await auth.presence();
    if (fresh != null) seen.value = fresh;
  }

  /// Отметка раз в минуту + запас на задержку опроса.
  static bool online(String id) {
    final t = seen.value[id];
    return t != null && DateTime.now().difference(t) < const Duration(minutes: 2, seconds: 30);
  }

  /// «в сети» / «был(а) в 14:05» / «был(а) 03.10» / null (не друг или неизвестно).
  static String? label(String id) {
    final t = seen.value[id]?.toLocal();
    if (t == null) return null;
    if (online(id)) return tr('в сети');
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay ? tr('был(а) в {p}:{p2}', {'p': two(t.hour), 'p2': two(t.minute)}) : tr('был(а) {p}.{p2}', {'p': two(t.day), 'p2': two(t.month)});
  }
}
