import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_settings.dart';

/// Кусок текста из базы знаний.
class KnowledgeChunk {
  final String table;
  final String source;
  final String heading;
  final String text;

  const KnowledgeChunk({
    required this.table,
    required this.source,
    required this.heading,
    required this.text,
  });
}

/// Поиск по справочным таблицам пользователя (Supabase REST / PostgREST).
///
/// Ищем ПО КЛЮЧЕВЫМ СЛОВАМ, а не по эмбеддингам — решение пользователя.
/// В таблицах эмбеддинги есть, но чтобы ими пользоваться, нужно на каждый
/// вопрос считать вектор запроса отдельным платным вызовом; поиск
/// подстрокой по `content` даёт достаточный результат бесплатно и
/// мгновенно.
///
/// Таблицы: `shooting_rules` (основы и правила стрельбы) и `books`
/// (книги по медицине, тренировкам и смежным темам).
class KnowledgeService {
  final AiSettings settings;
  final http.Client _client;

  KnowledgeService(this.settings, {http.Client? client})
      : _client = client ?? http.Client();

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

  /// Слова короче этого в поиск не идут — от «как», «что», «мне» толку
  /// нет, а выдачу они размывают до бессмыслицы.
  static const int minWordLength = 5;

  /// Служебные слова, которые проходят по длине, но смысла не несут.
  static const Set<String> _stopWords = {
    'который',
    'которая',
    'потому',
    'нужно',
    'можно',
    'почему',
    'сколько',
    'какой',
    'какая',
    'какие',
    'когда',
    'сейчас',
    'вообще',
    'вопрос',
    'ответь',
    'скажи',
    'расскажи',
    'подскажи',
    'объясни',
    'пожалуйста',
    // Длинные, но пустые: «максимальная глубина затыльника» — искать
    // надо затыльник, а «максимальная» встречается на каждой странице
    // и забивает выдачу мусором. Слово длиннее — значит по нашей
    // сортировке оно шло ПЕРВЫМ, то есть вредило сильнее всех.
    'максимальная',
    'максимальный',
    'максимально',
    'минимальная',
    'минимальный',
    'минимально',
    'разрешено',
    'разрешается',
    'допустимо',
    'допускается',
    'правильно',
    'обычно',
    'лучше',
    'должен',
    'должна',
    'должно',
  };

  /// Ключевые слова вопроса.
  ///
  /// Морфологии нет, поэтому у длинных слов берём только основу — первые
  /// 6 букв. «стрельбе», «стрельбы», «стрельбой» превращаются в
  /// «стрель» и находят друг друга. Грубо, но для подстрочного поиска
  /// работает лучше, чем точное совпадение словоформы.
  static List<String> keywords(String question) {
    final words = question
        .toLowerCase()
        .replaceAll(RegExp(r'[^\wа-яё\s]', unicode: true), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.length >= minWordLength && !_stopWords.contains(w))
        .toList();

    // Длинные слова информативнее коротких — берём их первыми.
    words.sort((a, b) => b.length.compareTo(a.length));

    final stems = <String>[];
    for (final w in words) {
      final stem = w.length > 6 ? w.substring(0, 6) : w;
      if (!stems.contains(stem)) stems.add(stem);
      if (stems.length >= 4) break;
    }
    return stems;
  }

  /// Начала реплик, за которыми в справочник лезть незачем.
  ///
  /// На «Добро» ассистент честно шёл искать по книгам: слово проходило
  /// и по длине, и мимо стоп-листа. Тратится время, а в запрос уезжает
  /// случайный кусок Канемана.
  ///
  /// Намеренно СПИСОК ПРЕФИКСОВ, а не регулярка: в Dart `\w` и `\b`
  /// работают только по ASCII, поэтому `привет\w*\b` на кириллице просто
  /// не сработал бы — и проверка тихо пропускала бы всё подряд.
  static const List<String> _smallTalkPrefixes = [
    'привет',
    'здравств',
    'добр',
    'хай',
    'спасибо',
    'пока',
    'ага',
    'как дела',
    'как сам',
    'что умеешь',
    'кто ты',
    'что ты умеешь',
  ];

  static bool isSmallTalk(String question) {
    final q = question.trim().toLowerCase();
    return _smallTalkPrefixes.any(q.startsWith);
  }

  /// Короче этого вопрос считаем репликой, а не запросом к справочнику.
  static const int minQuestionLength = 8;

  /// Сколько строк тянем на КАЖДОЕ ключевое слово, прежде чем отбирать
  /// лучшие. Берём с запасом: выбрать два подходящих из десяти лучше,
  /// чем взять первые два, какие отдал сервер.
  static const int perWordFetch = 4;

  /// Сколько записей в каждой таблице базы знаний.
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
    if (!settings.booksConfigured) {
      return {'база': 'не задан URL'};
    }
    final token = settings.booksToken;
    for (final table in settings.tables) {
      try {
        final uri = Uri.parse('${settings.booksUrl}/$table')
            .replace(queryParameters: {'select': 'content'});
        final res = await _client.get(uri, headers: {
          'Accept': 'application/json',
          'Prefer': 'count=exact',
          'Range': '0-0',
          if (token.isNotEmpty) 'apikey': token,
          if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        }).timeout(_timeout);

        if (res.statusCode >= 400) {
          out[table] = 'ошибка ${res.statusCode}';
          continue;
        }
        // content-range приходит в виде «0-0/128» или «*/0».
        final range = res.headers['content-range'] ?? '';
        final total = range.contains('/') ? range.split('/').last : '?';
        out[table] = total == '0' ? 'пусто' : '$total записей';
      } catch (e) {
        out[table] = 'недоступна';
      }
    }
    return out;
  }

  /// Ищет по обеим таблицам. Пустой список — не нашли, не искали или
  /// база недоступна; для чата это не ошибка, просто ответ будет без
  /// справочных материалов.
  ///
  /// Схема поиска: на каждое ключевое слово — свой запрос, потом все
  /// найденные куски ранжируются по тому, сколько РАЗНЫХ слов вопроса
  /// в них встречается. Раньше был один общий запрос `or=(...)` с
  /// лимитом 2, и сервер отдавал просто две первые попавшиеся строки,
  /// где нашлось хоть одно слово, — на вопрос про затыльник приезжал
  /// случайный абзац, где было слово «глубина».
  Future<List<KnowledgeChunk>> search(String question) async {
    if (!settings.booksConfigured) return const [];
    final trimmed = question.trim();
    if (trimmed.length < minQuestionLength) return const [];
    if (isSmallTalk(trimmed)) return const [];
    final words = keywords(trimmed);
    if (words.isEmpty) return const [];

    final results = <KnowledgeChunk>[];
    for (final table in settings.tables) {
      // Запросы по словам — параллельно: это одна и та же база, и
      // ждать их по очереди значит втрое затянуть ответ в чате.
      final batches = await Future.wait([
        for (final w in words) _searchTable(table, w),
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
  static int _relevance(KnowledgeChunk c, List<String> words) {
    final hay = '${c.heading} ${c.text}'.toLowerCase();
    var n = 0;
    for (final w in words) {
      if (hay.contains(w)) n++;
    }
    return n;
  }

  Future<List<KnowledgeChunk>> _searchTable(String table, String word) async {
    try {
      final uri = Uri.parse('${settings.booksUrl}/$table').replace(
        queryParameters: {
          'select': 'file_name,heading_path,content',
          'content': 'ilike.*$word*',
          'limit': '$perWordFetch',
        },
      );

      final token = settings.booksToken;
      final res = await _client.get(uri, headers: {
        'Accept': 'application/json',
        if (token.isNotEmpty) 'apikey': token,
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      }).timeout(_timeout);

      // 400 — в таблице нет ожидаемых колонок. Это не повод рушить чат:
      // просто пропускаем таблицу.
      if (res.statusCode != 200) return const [];

      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is! List) return const [];

      return [
        for (final row in data)
          if (row is Map && row['content'] is String)
            KnowledgeChunk(
              table: table,
              source: '${row['file_name'] ?? table}',
              heading: '${row['heading_path'] ?? ''}',
              text: _clean('${row['content']}'),
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
      final piece = '[${c.source}${c.heading.isEmpty ? '' : ', ${c.heading}'}]\n${c.text}\n\n';
      if (buf.length + piece.length > totalCharLimit) break;
      buf.write(piece);
    }
    final out = buf.toString().trim();
    return out.isEmpty ? null : out;
  }
}
