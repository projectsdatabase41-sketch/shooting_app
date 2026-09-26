import 'dart:convert';

import '../services/local_db_service.dart';

/// Одна подключённая таблица базы знаний — имя (для запроса к базе),
/// название и краткое описание (чтобы ИИ понимал, что там лежит и как
/// доверять найденному — пункт 12 списка правок). Название/описание
/// необязательны: старые записи (когда хранилось только имя) читаются
/// как есть, без названия.
class KnowledgeTableConfig {
  final String name;
  final String label;
  final String description;

  /// Какая колонка содержит текст для поиска. По умолчанию `content` —
  /// так были устроены исходные shooting_rules/books, но таблица со
  /// своей структурой (например, чужая `notes`) может называть её
  /// иначе — отсюда настройка, а не жёстко зашитое имя.
  final String contentColumn;

  const KnowledgeTableConfig({
    required this.name,
    String? label,
    this.description = '',
    this.contentColumn = 'content',
  }) : label = label ?? name;

  factory KnowledgeTableConfig.fromJson(Map<String, dynamic> json) => KnowledgeTableConfig(
        name: json['name'] as String,
        label: json['label'] as String?,
        description: json['description'] as String? ?? '',
        contentColumn: json['content_column'] as String? ?? 'content',
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'label': label,
        'description': description,
        'content_column': contentColumn,
      };
}

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
  static const String keyTables = 'ai_tables';
  static const String keyCustomInstructions = 'ai_custom_instructions';
  static const String keyApiBaseUrl = 'ai_api_base_url';
  static const String keyLocalMode = 'ai_local_mode';
  static const String keyLocalModel = 'ai_local_model';
  static const String keyVisionModel = 'ai_vision_model';

  /// Все ключи ИИ — чтобы «сбросить все цвета» их не снесло.
  static const List<String> allKeys = [
    keyApiKey,
    keyModels,
    keyTables,
    keyCustomInstructions,
    keyApiBaseUrl,
  ];

  /// Совпадает с `AiService.defaultBase` — не импортируем сам сервис
  /// сюда, чтобы не заводить встречный импорт ради одной константы.
  static const String defaultApiBaseUrl = 'https://openrouter.ai/api/v1';

  /// Адрес API OpenRouter — обычно трогать не нужно. Настраиваемый
  /// ради единственного случая: openrouter.ai заблокирован в регионе
  /// пользователя (403 без VPN, мгновенно работает с ним) — код это не
  /// чинит, но свой прокси/зеркало с тем же API подключить можно.
  /// Локальная модель (lib/local_ai/): 'off' | 'tasks' | 'all'.
  String get localMode => _read(keyLocalMode, fallback: 'off');
  set localMode(String v) => _write(keyLocalMode, v);

  /// id из `localModelCatalog`.
  String get localModelId => _read(keyLocalModel);
  set localModelId(String v) => _write(keyLocalModel, v);

  /// id из `visionModelCatalog` — распознавание пробоин по фото (отдельно
  /// от текстовой локальной модели).
  String get visionModelId => _read(keyVisionModel);
  set visionModelId(String v) => _write(keyVisionModel, v);

  String get apiBaseUrl => _read(keyApiBaseUrl, fallback: defaultApiBaseUrl);
  set apiBaseUrl(String v) => _write(keyApiBaseUrl, v.trim().replaceAll(RegExp(r'/+$'), ''));

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

  /// Ещё запасные встроенные ключи — тот же принцип, что у [testApiKey]
  /// (только на сборке, в git не попадают). Если у одного кончился
  /// дневной/минутный лимit бесплатных моделей, `AiService.ask()`
  /// пробует следующий ключ целиком со своей цепочкой моделей, а не
  /// сдаётся сразу (пользователь принёс несколько ключей именно для
  /// такого автоматического переключения).
  static const String testApiKey2 = String.fromEnvironment('OPENROUTER_KEY_2');
  static const String testApiKey3 = String.fromEnvironment('OPENROUTER_KEY_3');
  static const String testApiKey4 = String.fromEnvironment('OPENROUTER_KEY_4');

  /// Все встроенные ключи по порядку — пустые (не переданные на сборке)
  /// отфильтрованы.
  static const List<String> testApiKeys = [
    if (testApiKey != '') testApiKey,
    if (testApiKey2 != '') testApiKey2,
    if (testApiKey3 != '') testApiKey3,
    if (testApiKey4 != '') testApiKey4,
  ];

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
  /// * `minimax/minimax-m3:free`, `minimax/minimax-m2.7:free` — стояли
  ///   здесь раньше, но провайдер убрал бесплатную версию совсем (404
  ///   «unavailable for free», проверено 2026-09-11 напрямую к
  ///   OpenRouter): не временная перегрузка, а постоянно мёртвая
  ///   строка в цепочке — юзер сообщал про "403 на все модели даже
  ///   после сброса лимита", и это отчасти оно: первая же попытка в
  ///   цепочке гарантированно проваливалась.
  ///
  /// Список на OpenRouter меняется постоянно, поэтому это только
  /// стартовое значение: в настройках есть «Обновить» (тянет живой
  /// список бесплатных) и «Проверить» (прогоняет цепочку запросом).
  static const List<String> defaultModels = [
    // --- Прошли и разговор, и разбор серий, и график. ---
    // Точная арифметика, рассуждения складывает в отдельное поле.
    'inclusionai/ling-3.0-flash-fin:free',
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

  /// Сохранённая цепочка КАК ЕСТЬ, без отката к дефолту — в отличие от
  /// [models]. Нужна экрану настроек: со своим ключом поле цепочки при
  /// первом открытии должно быть пустым (решение пользователя), а не
  /// подставлять модели, подобранные под встроенный бесплатный ключ.
  String get rawModels => _read(keyModels);

  /// Общая база разработчика — книги, правила стрельбы и прочий
  /// справочный материал, ОДИН на всех пользователей приложения, а не в
  /// личном проекте каждого (решение пользователя, пункт 2/10 списка
  /// правок: "справочные материалы вшиты и скрыты внутри приложения").
  /// Адрес и публикуемый ключ поэтому зашиты как константы — ни то, ни
  /// другое больше не редактируется в настройках.
  static const String booksUrl = 'https://yirvomezybprdlntxyas.supabase.co/rest/v1';
  static const String booksToken = 'sb_publishable_2nW7G7lKueMQamuFeoC3Cw_iql48Xj3';

  /// Таблицы общей базы, вшитые в приложение — всегда активны, нигде в
  /// настройках не показываются и не редактируются.
  static const List<KnowledgeTableConfig> builtInTables = [
    KnowledgeTableConfig(name: 'shooting_rules', label: 'Правила стрельбы'),
    KnowledgeTableConfig(name: 'books', label: 'Книги'),
  ];

  /// Таблицы из ЛИЧНОЙ базы пользователя (та же, что хранит тренировки —
  /// `SupabaseAuthService`), которые он сам подключил как справочник для
  /// ИИ — список заполняется в настройках учётной записи (пункт 3/8
  /// списка правок), не здесь.
  ///
  /// Хранится JSON-массивом. Старый формат (простой список имён через
  /// запятую, до появления названий/описаний) распознаётся отдельно —
  /// у существующих пользователей подключённые таблицы не должны
  /// пропасть только из-за смены формата хранения.
  List<KnowledgeTableConfig> get tables {
    List<KnowledgeTableConfig> parse() {
      final raw = _read(keyTables);
      if (raw.isEmpty) return const [];
      if (raw.trimLeft().startsWith('[')) {
        try {
          final decoded = jsonDecode(raw) as List;
          return decoded.cast<Map<String, dynamic>>().map(KnowledgeTableConfig.fromJson).toList();
        } catch (_) {
          return const [];
        }
      }
      // Старый формат — простые имена через запятую.
      final names = raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      return [for (final n in names) KnowledgeTableConfig(name: n)];
    }

    // Записи с именем встроенной таблицы отфильтровываются даже если уже
    // сохранены — до этой правки shooting_rules/books попадали сюда по
    // умолчанию, и у пользователей, успевших открыть и сохранить
    // настройки ассистента раньше, они застряли в списке личных таблиц
    // навсегда, хотя интерфейс их больше не добавляет.
    final builtInNames = {for (final t in builtInTables) t.name};
    return parse().where((t) => !builtInNames.contains(t.name)).toList();
  }

  set tables(List<KnowledgeTableConfig> v) => _write(keyTables, jsonEncode([for (final t in v) t.toJson()]));

  /// Таблицы, которые заводит сама схема приложения (`sql/schema.sql`) в
  /// ЛИЧНОЙ базе пользователя — исключаются из списка при подключении
  /// таблиц для ИИ-справочника (пункт 8 списка правок: "фильтр на
  /// названия таблиц... имеющих отношение к работе приложения"), иначе
  /// список для подключения предлагал бы подключить тренировки/выстрелы
  /// как будто это справочный материал.
  static const Set<String> appOwnTables = {
    'project_settings',
    'target_faces',
    'exercise_templates',
    'training_packages',
    'exercises',
    'file_assets',
    'photo_import_jobs',
    'shots',
    'remote_athlete_sources',
    'archived_packages',
    'share_grants',
    'share_events',
    'comments',
    'training_notes',
    'ai_conversation_summaries',
    // служебные таблицы установщика (lib/db/puls_install.sql)
    'keepalive_log',
    'table_docs',
    'table_protection',
  };

  /// Короткая инструкция от пользователя — что ассистенту стоит знать
  /// или как себя вести, поверх общего системного промпта.
  String get customInstructions => _read(keyCustomInstructions);
  set customInstructions(String v) => _write(keyCustomInstructions, v.trim());

  /// Предел длины пользовательской инструкции, символов. Со встроенным
  /// (бесплатным) ключом контекст короче и дороже каждого лишнего
  /// токена — со своим ключом (обычно платным) модель переваривает
  /// заметно больше текста, поэтому предел там намного шире.
  static const int customInstructionsLimitBuiltIn = 300;
  static const int customInstructionsLimitOwnKey = 2000;

  int get customInstructionsLimit =>
      hasOwnKey ? customInstructionsLimitOwnKey : customInstructionsLimitBuiltIn;
}
