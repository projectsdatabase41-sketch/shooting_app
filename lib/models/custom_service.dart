/// Плитка стороннего сервиса (решение пользователя, раздел настроек
/// "Сервисы") — Google Drive, Supabase, заметки и т.п. Пользователь сам
/// описывает подключение одним из трёх способов (см.
/// `lib/logic/service_connection_parser.dart`): просто ссылкой, cURL-командой
/// (скопированной, например, из документации API) или JSON-объектом
/// `{"url":..., "method":..., "headers":{...}, "body":...}`. Из всех трёх
/// в итоге получается один и тот же набор полей ниже.
class CustomService {
  final String id;
  final String name;

  /// Ключ в `serviceIcons` (`lib/widgets/service_icon_picker.dart`) — сама
  /// `IconData` не сериализуется, поэтому храним имя из фиксированного
  /// набора, а не произвольную иконку.
  final String iconName;

  final String url;
  final String method;

  /// Пусто — просто ссылка (открывается во внешнем браузере, как сайт
  /// сервиса); непусто — вероятно, вызов API, тогда плитка предлагает
  /// ещё и выполнить запрос прямо в приложении и показать ответ.
  final Map<String, String> headers;
  final String? body;

  const CustomService({
    required this.id,
    required this.name,
    required this.iconName,
    required this.url,
    this.method = 'GET',
    this.headers = const {},
    this.body,
  });

  /// Простая ссылка (сайт/дашборд) — без заголовков и тела запроса
  /// открывать её как API нет смысла, это обычная веб-страница.
  bool get isPlainLink => headers.isEmpty && body == null && method == 'GET';
}
