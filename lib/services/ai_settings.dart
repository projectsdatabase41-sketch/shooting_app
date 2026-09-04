import '../services/local_db_service.dart';

/// Настройки ИИ-ассистента: ключ OpenRouter, цепочка моделей и адрес
/// таблицы с книгами.
///
/// Хранятся в той же key-value таблице `color_prefs`, что и тема
/// интерфейса — это простое хранилище «ключ → строка», заводить ради
/// четырёх строк отдельную таблицу и миграцию избыточно.
class AiSettings {
  final LocalDbService db;

  AiSettings(this.db);

  static const String keyApiKey = 'ai_api_key';
  static const String keyModels = 'ai_models';
  static const String keyBooksUrl = 'ai_books_url';
  static const String keyBooksToken = 'ai_books_token';
  static const String keyTables = 'ai_tables';

  /// Все ключи ИИ — чтобы «сбросить все цвета» их не снесло.
  static const List<String> allKeys = [
    keyApiKey,
    keyModels,
    keyBooksUrl,
    keyBooksToken,
    keyTables,
  ];

  /// Тестовый ключ OpenRouter. В исходниках его больше НЕТ — он
  /// приходит на сборку: `--dart-define=OPENROUTER_KEY=sk-or-...`.
  ///
  /// Причина ровно одна и она практическая: для бесплатного GitHub
  /// Pages репозиторий должен быть публичным, а живой ключ в публичном
  /// репозитории находят сканеры GitHub и отзывают за минуты — вместе
  /// со всеми остальными местами, где он используется.
  ///
  /// Секретным ключ от этого НЕ становится: в собранном `main.dart.js`
  /// он всё равно лежит открытым текстом, как лежал в APK и в exe.
  /// Клиентское приложение секретов хранить не умеет в принципе. Речь
  /// только о том, чтобы ключ не жил в git.
  ///
  /// Без `--dart-define` строка пустая, и приложение работает по
  /// ключу, введённому в настройках — обычный путь для любой чужой
  /// сборки.
  static const String testApiKey = String.fromEnvironment('OPENROUTER_KEY');

  /// Модели по умолчанию — бесплатные на OpenRouter, по приоритету.
  ///
  /// Список НЕ выдуман: все бесплатные модели OpenRouter (21 штука на
  /// 02.09.2026) были прогнаны этим же ключом сначала простым «привет»,
  /// а потом настоящей задачей — системный промпт ассистента плюс
  /// контекст на 40 выстрелов и вопрос «сравни серии по среднему и
  /// кучности, покажи график». В цепочку попали только те, кто дал
  /// готовый ответ, а не обрывок рассуждения, и приложил корректный
  /// блок ```chart. Порядок — по точности арифметики и «молчаливости»
  /// (чем меньше модель рассуждает вслух, тем быстрее и дешевле ответ).
  ///
  /// Отсеяны и почему:
  /// * `thinkingmachines/inkling*` — 403, «only available on agentic
  ///   harnesses»: обычному приложению не отдаются в принципе.
  /// * `poolside/laguna-*`, `z-ai/glm-5.2` — 404, их провайдера нет в
  ///   списке разрешённых у аккаунта (настройка Privacy на OpenRouter).
  /// * `google/gemma-4-*` — 429, провайдер отдаёт отказ по нагрузке.
  /// * `nvidia/nemotron-3.5-lightning`, `openrouter/free`,
  ///   `nemotron-3-super-120b`, `nemotron-3-ultra-550b`,
  ///   `cohere/north-mini-code`, `liquid/lfm-2.5-2.6b` — на простом
  ///   «привет» отвечают, а на реальной задаче упираются в лимит
  ///   токенов ПОСРЕДИ рассуждения и до ответа не доходят вовсе.
  ///   Именно они и стояли в прежней цепочке.
  /// * `nvidia/nemotron-3.5-content-safety` — это модератор, а не
  ///   собеседник: на любой вопрос отвечает «User Safety: safe».
  ///
  /// Список на OpenRouter меняется постоянно, поэтому это только
  /// стартовое значение: в настройках есть «Обновить» (тянет живой
  /// список бесплатных) и «Проверить» (прогоняет цепочку запросом).
  static const List<String> defaultModels = [
    // --- Прошли и разговор, и разбор серий, и график. ---
    // Не рассуждает вообще; все четыре средних по сериям — точно.
    'minimax/minimax-m3:free',
    // Точная арифметика, рассуждения складывает в отдельное поле.
    'inclusionai/ling-3.0-flash-fin:free',
    // Ответ аккуратный, одно среднее из четырёх — мимо на 0.05.
    'minimax/minimax-m2.7:free',
    // Считает верно, но рассуждает много: ответ дороже и медленнее.
    'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free',
    // Формат держит, в арифметике ошибается (9.83 вместо 9.94).
    'dots-studio/dots-3-note-preview:free',

    // --- Ниже те, кто разговор поддерживает, а разбор данных не
    // тянет: уходят в рассуждение и упираются в лимит токенов. Держим
    // хвостом на случай, если верхние разом откажут: на «привет» и
    // «что умеешь» они отвечают нормально. ---
    'nvidia/nemotron-3-super-120b-a12b:free',
    'cohere/north-mini-code:free',
    'liquid/lfm-2.5-2.6b:free',
    'nvidia/nemotron-3.5-lightning:free',
  ];

  String _read(String key, {String fallback = ''}) {
    final rows = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [key]);
    if (rows.isEmpty) return fallback;
    final v = rows.first['hex'] as String?;
    return (v == null || v.isEmpty) ? fallback : v;
  }

  void _write(String key, String value) {
    db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      [key, value],
    );
  }

  /// Ключ из настроек, а если пользователь свой не вводил — тестовый.
  String get apiKey => _read(keyApiKey, fallback: testApiKey);
  set apiKey(String v) => _write(keyApiKey, v.trim());

  /// Введён ли собственный ключ (а не используется зашитый тестовый).
  bool get hasOwnKey => _read(keyApiKey).isNotEmpty;

  List<String> get models {
    final raw = _read(keyModels);
    if (raw.isEmpty) return defaultModels;
    final list = raw.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    return list.isEmpty ? defaultModels : list;
  }

  set models(List<String> v) => _write(keyModels, v.join('\n'));

  /// База знаний по умолчанию — публичная таблица пользователя.
  /// Как и тестовый ключ, это значение можно перекрыть в настройках.
  static const String defaultBooksUrl =
      'https://yirvomezybprdlntxyas.supabase.co/rest/v1';
  static const String defaultBooksToken =
      'sb_publishable_2nW7G7lKueMQamuFeoC3Cw_iql48Xj3';

  /// Таблицы базы знаний ПО УМОЛЧАНИЮ. Ищутся по тексту колонки
  /// `content`: `shooting_rules` — основы и правила стрельбы, `books` —
  /// книги по медицине, тренировкам и смежным темам.
  ///
  /// Это только стартовое значение: список редактируется в настройках,
  /// потому что таблиц у пользователя со временем станет больше, а
  /// пересобирать приложение ради имени таблицы — нелепо.
  static const List<String> knowledgeTables = ['shooting_rules', 'books'];

  /// Таблицы, по которым ассистент ищет сейчас.
  List<String> get tables {
    final raw = _read(keyTables);
    if (raw.isEmpty) return knowledgeTables;
    final list = raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    return list.isEmpty ? knowledgeTables : list;
  }

  set tables(List<String> v) =>
      _write(keyTables, v.map((e) => e.trim()).where((e) => e.isNotEmpty).join(','));

  String get booksUrl => _read(keyBooksUrl, fallback: defaultBooksUrl);
  set booksUrl(String v) => _write(keyBooksUrl, v.trim());

  String get booksToken => _read(keyBooksToken, fallback: defaultBooksToken);
  set booksToken(String v) => _write(keyBooksToken, v.trim());

  bool get booksConfigured => booksUrl.isNotEmpty;
}
