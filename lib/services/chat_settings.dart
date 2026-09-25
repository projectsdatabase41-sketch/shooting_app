import 'remote_config.dart';

/// Публичный чат — общий бэкенд ОДИН на всех пользователей приложения
/// (отдельный проект Supabase, только транзит сообщений между разными
/// личными аккаунтами — тот же принцип, что и у общей базы книг/правил,
/// см. `AiSettings.booksUrl`/`booksToken`), а не тот, что у каждого
/// пользователя хранит тренировки.
///
/// Адрес и ключ ПОКА пустые — этот проект ещё не создан (пользователь
/// заведёт его отдельно, накатит `sql/chat-schema.sql` и пришлёт
/// url/anon key). Вся локальная часть чата (контакты, история переписки,
/// статусы отправки) работает уже сейчас без них; сетевой обмен
/// включится сам, как только здесь появятся настоящие значения —
/// остальной код чата их не хардкодит нигде повторно.
class ChatSettings {
  // Сервер мессенджера — публичная база (та же, что книги/правила для ИИ).
  static const String _defaultUrl = 'https://yirvomezybprdlntxyas.supabase.co';
  static const String _defaultAnonKey = 'sb_publishable_2nW7G7lKueMQamuFeoC3Cw_iql48Xj3';

  /// Адрес и ключ можно сменить удалённо (`RemoteConfig`, только вместе и
  /// только для *.supabase.co) — без выпуска новой версии.
  static String get url => RemoteConfig.chatUrl != null && RemoteConfig.chatAnonKey != null
      ? RemoteConfig.chatUrl!
      : _defaultUrl;
  static String get anonKey => RemoteConfig.chatUrl != null && RemoteConfig.chatAnonKey != null
      ? RemoteConfig.chatAnonKey!
      : _defaultAnonKey;

  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;
}
