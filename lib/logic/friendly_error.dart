import 'dart:async';

import '../i18n/i18n.dart';

/// Включён «режим разработчика» — тогда ошибки показываются как есть,
/// со всеми подробностями. Выставляет `PersonalizationViewModel`.
bool friendlyErrorDevMode = false;

/// Понятное пользователю описание ошибки. В режиме разработчика —
/// исходный текст. Обычным пользователям не нужны «HTTP 403» и
/// «[firebase_messaging/...]», нужно понимать, что делать.
String friendlyError(Object e) {
  final raw = '$e'
      .replaceFirst(
          RegExp(
              r'^(Exception|AuthException|AiException|StateError|FormatException): '),
          '')
      .trim();
  if (friendlyErrorDevMode) return raw;
  final s = raw.toLowerCase();

  if (e is TimeoutException ||
      s.contains('timeout') ||
      s.contains('timed out')) {
    return tr(
        'Нет ответа от сервера — проверьте интернет и попробуйте ещё раз');
  }
  if (s.contains('socketexception') ||
      s.contains('failed host lookup') ||
      s.contains('clientexception') ||
      s.contains('network is unreachable') ||
      s.contains('connection refused') ||
      s.contains('connection closed') ||
      s.contains('xmlhttprequest')) {
    return tr('Нет связи с сервером — проверьте интернет');
  }
  // Сообщение, которое мы сами написали по-русски и коротко, — уже человеческое.
  if (RegExp(r'[А-Яа-яЁё]').hasMatch(raw) &&
      raw.length < 200 &&
      !s.contains('exception')) return raw;

  if (RegExp(r'\b(401|403)\b').hasMatch(s) ||
      s.contains('jwt') ||
      s.contains('permission denied') ||
      s.contains('row-level') ||
      s.contains('not authorized')) {
    return tr('Нет доступа — войдите заново или проверьте настройки доступа');
  }
  if (RegExp(r'\b404\b').hasMatch(s) ||
      s.contains('does not exist') ||
      s.contains('not found')) {
    return tr('Не найдено — возможно, в базе не выполнен нужный SQL-скрипт');
  }
  if (RegExp(r'\b429\b').hasMatch(s) ||
      s.contains('rate limit') ||
      s.contains('too many')) {
    return tr('Слишком много запросов — подождите немного и повторите');
  }
  if (RegExp(r'\b5\d\d\b').hasMatch(s))
    return tr('Сервер временно недоступен — попробуйте позже');
  if (e is FormatException ||
      s.contains('formatexception') ||
      s.contains('unexpected character')) {
    return tr('Не удалось разобрать ответ сервера');
  }
  return tr(
      'Что-то пошло не так. Повторите попытку; подробности — в режиме разработчика');
}
