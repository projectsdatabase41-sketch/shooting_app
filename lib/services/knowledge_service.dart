import 'dart:convert';

import 'package:http/http.dart' as http;

import '../logic/text_search.dart';
import 'ai_service.dart';
import 'ai_settings.dart';
import 'knowledge_column_discovery.dart';
import 'local_db_service.dart';
import 'supabase_auth_service.dart';

/// Кусок текста из базы знаний.
class KnowledgeChunk {
  final String table;
  final String tableLabel;
  final String tableDescription;
  final String source;
  final String heading;
  final String text;

  const KnowledgeChunk({
    required this.table,
    required this.tableLabel,
    this.tableDescription = '',
    required this.source,
    required this.heading,
    required this.text,
  });
}

/// Одна подключённая таблица вместе с адресом/ключом, по которым её
/// искать — общая база разработчика (книги/правила) и личная база
/// пользователя (его собственные таблицы) физически разные проекты
/// Supabase, поэтому у каждой таблицы свой адрес.
typedef _SourceTable = (KnowledgeTableConfig table, String baseUrl, String token);

/// Поиск по справочным таблицам (Supabase REST / PostgREST).
///
/// Ищем ПО КЛЮЧЕВЫМ СЛОВАМ, а не по эмбеддингам — решение пользователя.
/// В таблицах эмбеддинги есть, но чтобы ими пользоваться, нужно на каждый
/// вопрос считать вектор запроса отдельным платным вызовом; поиск
/// подстрокой по `content` даёт достаточный результат бесплатно и
/// мгновенно.
///
/// Источников теперь два (пункт 2/3/8 списка правок):
/// * `AiSettings.builtInTables` — вшитые в приложение таблицы ОБЩЕЙ базы
///   разработчика (`AiSettings.booksUrl`/`booksToken`, константы).
/// * `settings.tables` — таблицы из ЛИЧНОЙ базы пользователя
///   (`personalAuth`), которые он сам подключил в настройках учётной
///   записи.
class KnowledgeService {
  final AiSettings settings;

  /// `null` — личная база не подключена (пользователь не вошёл), тогда
  /// ищем только по общей базе разработчика.
  final SupabaseAuthService? personalAuth;

  /// Определение колонки с текстом у таблиц, где она не `content` —
  /// см. `KnowledgeColumnDiscovery`. Оба параметра нужны только для
  /// него: `db` — куда кешировать результат, `aiService` — кем спросить.
  final LocalDbService db;
  final AiService aiService;
  late final KnowledgeColumnDiscovery _discovery = KnowledgeColumnDiscovery(db);

  final http.Client _client;

  KnowledgeService(
    this.settings, {
    required this.db,
    required this.aiService,
    this.personalAuth,
    http.Client? client,
  }) : _client = client ?? http.Client();

  static const Duration _timeout = Duration(seconds: 20);

  /// Сколько кусков берём из каждой таблицы.
  static const int perTableLimit = 3;

  /// Предел на один кусок и на всю выдачу, символов.
  ///
  /// Куски в базе бывают под 2000 символов, а окно бесплатной модели
  /// маленькое. Режем на нашей стороне: лучше отдать модели три коротких
  /// фрагмента, чем один огромный и получить ошибку переполнения.
  static const int chunkCharLimit = 1200;
  static const int totalCharLimit = 6000;

  /// Ключевые слова и «это болтовня, не вопрос» — общая логика,
  /// см. `TextSearch` (вынесена оттуда же, где раньше жила здесь одна,
  /// чтобы `AiMemoryService` не заводил тот же стоп-лист заново).
  static List<String> keywords(String question) => TextSearch.keywords(question);
  static bool isSmallTalk(String question) => TextSearch.isSmallTalk(question);

  /// Короче этого вопрос считаем репликой, а не запросом к справочнику.
  static const int minQuestionLength = TextSearch.minQuestionLength;

  /// Сколько строк тянем на КАЖДОЕ ключевое слово, прежде чем отбирать
  /// лучшие. Берём с запасом: выбрать два подходящих из десяти лучше,
  /// чем взять первые два, какие отдал сервер.
  static const int perWordFetch = 4;

  /// Все подключённые таблицы вместе с адресом/ключом для запроса —
  /// вшитые (общая база) + личные пользователя, если она подключена.
  /// Колонка с текстом — не обязательно `content` по умолчанию, а
  /// определённая один раз через `KnowledgeColumnDiscovery` (решение
  /// пользователя: раньше "правила" и самостоятельно подключённые
  /// таблицы вроде заметок молча не находились, если их текстовая
  /// колонка называлась иначе).
  Future<List<_SourceTable>> _allTables() async {
    final out = <_SourceTable>[];
    for (final t in AiSettings.builtInTables) {
      out.add((await _withDiscoveredColumn(t, AiSettings.booksUrl, AiSettings.booksToken), AiSettings.booksUrl, AiSettings.booksToken));
    }
    final auth = personalAuth;
    if (auth != null && auth.hasBase && settings.tables.isNotEmpty) {
      final token = await auth.ensureFreshToken() ?? auth.anonKey;
      final baseUrl = '${auth.url}/rest/v1';
      for (final t in settings.tables) {
        out.add((await _withDiscoveredColumn(t, baseUrl, token), baseUrl, token));
      }
    }
    return out;
  }

  Future<KnowledgeTableConfig> _withDiscoveredColumn(KnowledgeTableConfig t, String baseUrl, String token) async {
    final column = await _discovery.discover(
      tableName: t.name,
      baseUrl: baseUrl,
      token: token,
      aiService: aiService,
    );
    if (column == null || column == t.contentColumn) return t;
    return KnowledgeTableConfig(name: t.name, label: t.label, description: t.description, contentColumn: column);
  }

  /// Сколько записей в каждой подключённой таблице.
  ///
  /// Когда ассистент отвечает «не моя тема», причин ровно две: он сам
  /// решил отказаться, или искать было негде. Отличить их без такой
  /// проверки невозможно — отсюда и кнопка в настройках.
  ///
  /// Считаем через `Prefer: count=exact` и `Range: 0-0`: PostgREST
  /// вернёт общее число в заголовке `content-range` и всего одну
  /// строку, так что тянуть всю таблицу ради счётчика не приходится.
  Future<Map<String, String>> tableStatus() async {
    final out = <String, String>{};
    for (final (table, baseUrl, token) in await _allTables()) {
      try {
        final uri = Uri.parse('$baseUrl/${table.name}')
            .replace(queryParameters: {'select': table.contentColumn});
        final res = await _client.get(uri, headers: {
          'Accept': 'application/json',
          'Prefer': 'count=exact',
          'Range': '0-0',
          if (token.isNotEmpty) 'apikey': token,
          if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        }).timeout(_timeout);

        if (res.statusCode >= 400) {
          out[table.label] = 'ошибка ${res.statusCode}';
          continue;
        }
        // content-range приходит в виде «0-0/128» или «*/0».
        final range = res.headers['content-range'] ?? '';
        final total = range.contains('/') ? range.split('/').last : '?';
        out[table.label] = total == '0' ? 'пусто' : '$total строк';
      } catch (e) {
        out[table.label] = 'недоступна';
      }
    }
    return out;
  }

  /// Ищет по всем подключённым таблицам. Пустой список — не нашли, не
  /// искали или база недоступна; для чата это не ошибка, просто ответ
  /// будет без справочных материалов.
  ///
  /// Схема поиска: на каждое ключевое слово — свой запрос, потом все
  /// найденные куски ранжируются по тому, сколько РАЗНЫХ слов вопроса
  /// в них встречается.
  Future<List<KnowledgeChunk>> search(String question) async {
    final trimmed = question.trim();
    if (trimmed.length < minQuestionLength) return const [];
    if (isSmallTalk(trimmed)) return const [];
    final words = keywords(trimmed);
    if (words.isEmpty) return const [];

    final results = <KnowledgeChunk>[];
    for (final (table, baseUrl, token) in await _allTables()) {
      // Запросы по словам — параллельно: это одна и та же база, и
      // ждать их по очереди значит втрое затянуть ответ в чате.
      final batches = await Future.wait([
        for (final w in words) _searchTable(table, w, baseUrl, token),
      ]);

      // Дедупликация по тексту: одно и то же слово в разных запросах
      // приводит к одной и той же строке.
      final unique = <String, KnowledgeChunk>{};
      for (final batch in batches) {
        for (final c in batch) {
          unique.putIfAbsent(c.text, () => c);
        }
      }

      final ranked = unique.values.toList()
        ..sort((a, b) => _relevance(b, words).compareTo(_relevance(a, words)));
      results.addAll(ranked.take(perTableLimit));
    }
    return results;
  }

  /// Сколько разных ключевых слов встретилось в куске. Заголовок весит
  /// столько же, сколько текст: попадание в заголовок раздела обычно
  /// значит, что раздел ровно про это.
  static int _relevance(KnowledgeChunk c, List<String> words) =>
      TextSearch.relevance('${c.heading} ${c.text}', words);

  Future<List<KnowledgeChunk>> _searchTable(
    KnowledgeTableConfig table,
    String word,
    String baseUrl,
    String token,
  ) async {
    try {
      // select=* вместо конкретных имён — file_name/heading_path не
      // обязаны существовать в чужой таблице (например, notes другого
      // ассистента), а contentColumn настраивается пользователем и не
      // обязан называться "content" (пункт: "хочу, чтобы ИИ мог читать
      // и заметки, и другие таблицы, которые я подключу").
      final uri = Uri.parse('$baseUrl/${table.name}').replace(
        queryParameters: {
          'select': '*',
          table.contentColumn: 'ilike.*$word*',
          'limit': '$perWordFetch',
        },
      );

      final res = await _client.get(uri, headers: {
        'Accept': 'application/json',
        if (token.isNotEmpty) 'apikey': token,
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      }).timeout(_timeout);

      // 400 — в таблице нет колонки, указанной как contentColumn. Это
      // не повод рушить чат: просто пропускаем таблицу.
      if (res.statusCode != 200) return const [];

      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is! List) return const [];

      return [
        for (final row in data)
          if (row is Map && row[table.contentColumn] is String)
            KnowledgeChunk(
              table: table.name,
              tableLabel: table.label,
              tableDescription: table.description,
              source: '${row['file_name'] ?? table.label}',
              heading: '${row['heading_path'] ?? ''}',
              text: _clean('${row[table.contentColumn]}'),
            )
      ];
    } catch (_) {
      return const [];
    }
  }

  /// В базе текст лежит с табуляциями вместо пробелов и переносами
  /// внутри слов — как его вытащили из PDF. В таком виде он и читается
  /// плохо, и токенов ест больше нужного.
  static String _clean(String raw) {
    final text = raw.replaceAll(RegExp(r'[\t\r\n]+'), ' ').replaceAll(RegExp(r' {2,}'), ' ').trim();
    return text.length <= chunkCharLimit ? text : '${text.substring(0, chunkCharLimit)}…';
  }

  /// Собирает найденное в блок для системного промпта, соблюдая общий
  /// лимит символов.
  static String? asPromptBlock(List<KnowledgeChunk> chunks) {
    if (chunks.isEmpty) return null;
    final buf = StringBuffer();
    for (final c in chunks) {
      // Название/описание таблицы — чтобы модель понимала, ЧТО за
      // источник перед ней (личный дневник — не то же самое, что
      // официальные правила ISSF, даже если оба совпали по слову),
      // а не только откуда файл (пункт 12 списка правок).
      final tableTag = c.tableDescription.isEmpty ? c.tableLabel : '${c.tableLabel}: ${c.tableDescription}';
      final piece = '[$tableTag — ${c.source}${c.heading.isEmpty ? '' : ', ${c.heading}'}]\n${c.text}\n\n';
      if (buf.length + piece.length > totalCharLimit) break;
      buf.write(piece);
    }
    final out = buf.toString().trim();
    return out.isEmpty ? null : out;
  }
}
