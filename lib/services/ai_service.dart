import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_settings.dart';

/// Ответ модели: текст плюс, если был, разобранный блок графика или
/// предложенного упражнения.
class AiReply {
  final String text;
  final Map<String, dynamic>? chart;
  final String model;

  /// Рассуждения модели, если она их выдала. Не выбрасываем, а
  /// показываем в чате отдельным свёрнутым блоком — так и ответ читаем,
  /// и видно, на чём модель основывалась.
  final String? reasoning;

  /// Предложенное упражнение (раздел 19 старого ТЗ: "создание
  /// упражнения по свободному описанию силами ассистента с показом
  /// результата на подтверждение"). Уже провалидировано белым списком —
  /// см. `AiService._splitExercise`; в интерфейсе только жмут "Создать".
  final Map<String, dynamic>? exercise;

  const AiReply({
    required this.text,
    required this.model,
    this.chart,
    this.reasoning,
    this.exercise,
  });
}

class AiException implements Exception {
  final String message;
  const AiException(this.message);
  @override
  String toString() => message;
}

/// Клиент OpenRouter с перебором моделей и чтением «книг».
///
/// Все бесплатные модели рано или поздно отвечают отказом (кончился
/// дневной лимит, модель убрали, перегруз), поэтому запрос идёт по
/// цепочке: не ответила первая — пробуем следующую. Наверх ошибка
/// уходит, только если не ответила ни одна.
class AiService {
  final AiSettings settings;
  final http.Client _client;

  AiService(this.settings, {http.Client? client}) : _client = client ?? http.Client();

  static const String _base = 'https://openrouter.ai/api/v1';
  static const Duration _timeout = Duration(seconds: 45);

  /// Список бесплатных моделей с сервера — для экрана настроек.
  Future<List<String>> fetchFreeModels() async {
    final res = await _client
        .get(Uri.parse('$_base/models'), headers: _headers())
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw AiException('Не удалось получить список моделей (${res.statusCode})');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final list = (data['data'] as List?) ?? const [];
    final free = <String>[];
    for (final m in list) {
      if (m is! Map) continue;
      final id = m['id'];
      final pricing = m['pricing'];
      if (id is! String || pricing is! Map) continue;
      final prompt = double.tryParse('${pricing['prompt']}') ?? 1;
      final completion = double.tryParse('${pricing['completion']}') ?? 1;
      if (prompt == 0 && completion == 0) free.add(id);
    }
    free.sort();
    return free;
  }

  /// Проверка одной модели: жива ли она вообще и доходит ли до ответа.
  ///
  /// Бесплатные модели на OpenRouter живут своей жизнью: одну убрали,
  /// вторая отдаётся только «агентным средам», у третьей провайдер не
  /// разрешён в настройках аккаунта, четвёртая отвечает «привет», но на
  /// настоящем вопросе упирается в лимит токенов посреди рассуждения.
  /// Разбираться в этом по сообщению «ни одна модель не ответила» —
  /// мучение, поэтому проверка вынесена в кнопку.
  ///
  /// Вопрос намеренно с арифметикой и просьбой построить график: модель,
  /// которая на «привет» отвечает, а здесь уходит в рассуждения, для
  /// ассистента бесполезна, и узнать это лучше заранее.
  Future<String> probeModel(String model) async {
    const system = 'Ты — ассистент по спортивной стрельбе. Отвечай коротко, по-русски, '
        'не рассуждай вслух. Выстрелы: (0.4, -1.2), (-0.8, 0.3), (1.1, 0.9) мм от центра.';
    const question = 'Посчитай СТП по этим трём выстрелам и добавь блок ```chart с типом bar.';

    final started = DateTime.now();
    try {
      final reply = await _askModel(
        model,
        const [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': question},
        ],
        settings.apiKey,
      );
      final ms = DateTime.now().difference(started).inMilliseconds;
      final chart = reply.chart == null ? '' : ', график';
      return 'ответила за ${(ms / 1000).toStringAsFixed(1)} с$chart';
    } on AiException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  /// Один запрос к модели. `history` — уже готовые сообщения диалога
  /// (роль + текст), без системного промпта: он добавляется здесь.
  Future<AiReply> ask({
    required String systemPrompt,
    required String contextBlock,
    required List<({String role, String text})> history,
    String? booksExcerpt,
  }) async {
    final key = settings.apiKey;
    if (key.isEmpty) {
      throw const AiException('Не задан ключ OpenRouter — укажите его в настройках');
    }

    final system = StringBuffer(systemPrompt)..writeln()..writeln(contextBlock);
    if (booksExcerpt != null && booksExcerpt.isNotEmpty) {
      system
        ..writeln()
        ..writeln('СПРАВОЧНЫЕ МАТЕРИАЛЫ (используй, только если вопрос о теории стрельбы):')
        ..writeln(booksExcerpt);
    }

    final messages = [
      {'role': 'system', 'content': system.toString()},
      for (final m in history) {'role': m.role, 'content': m.text},
    ];

    final errors = <String>[];
    for (final model in settings.models) {
      try {
        return await _askModel(model, messages, key);
      } on AiException catch (e) {
        errors.add('$model: ${e.message}');
      } catch (e) {
        errors.add('$model: $e');
      }
    }
    throw AiException('Ни одна модель не ответила.\n${errors.join('\n')}');
  }

  Future<AiReply> _askModel(
    String model,
    List<Map<String, String>> messages,
    String key,
  ) async {
    final res = await _client
        .post(
          Uri.parse('$_base/chat/completions'),
          headers: {..._headers(), 'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': model,
            'messages': messages,
            // Лимит подняли: рассуждающие модели упирались в 900 токенов
            // ПОСРЕДИ размышления и до самого ответа не доходили — в чат
            // приезжал обрывок рассуждения вместо ответа.
            'max_tokens': 2000,
            'temperature': 0.3,
            // Просим отдавать рассуждения ОТДЕЛЬНЫМ полем, а не мешать
            // их в текст ответа. Поддерживают не все модели — поэтому
            // ниже есть ещё два рубежа обороны (поле reasoning и разбор
            // текста в _split).
            'reasoning': {'exclude': false},
          }),
        )
        .timeout(_timeout);

    if (res.statusCode != 200) {
      throw AiException(_errorFrom(res));
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw const AiException('пустой ответ');
    }
    final message = (choices.first as Map)['message'];
    final content = message?['content'];
    if (content is! String || content.trim().isEmpty) {
      throw const AiException('пустой ответ');
    }

    // Часть моделей кладёт рассуждения в отдельное поле, часть — прямо
    // в content, а некоторые — в оба места сразу. Склеиваем, но без
    // дублей: иначе один и тот же текст показывался дважды.
    final fieldReasoning = message?['reasoning'];
    final split = splitReasoning(content.trim());
    final parts = <String>[];
    if (fieldReasoning is String && fieldReasoning.trim().isNotEmpty) {
      parts.add(fieldReasoning.trim());
    }
    final inline = split.$2;
    if (inline != null && !parts.any((p) => p.contains(inline) || inline.contains(p))) {
      parts.add(inline);
    }
    final reasoning = parts.join('\n\n');

    final parsedChart = _splitChart(split.$1);
    final parsedExercise = _splitExercise(parsedChart.$1);

    // Модель зарассуждалась и до ответа не дошла. Это не ответ, а
    // мусор — пробуем следующую модель в цепочке вместо того, чтобы
    // показывать пользователю обрывок чужих мыслей.
    if (parsedExercise.$1.trim().isEmpty) {
      throw const AiException('модель не дошла до ответа');
    }

    return AiReply(
      text: parsedExercise.$1,
      chart: parsedChart.$2,
      exercise: parsedExercise.$2,
      model: model,
      reasoning: reasoning.isEmpty ? null : reasoning,
    );
  }

  Map<String, String> _headers() => {
        'Authorization': 'Bearer ${settings.apiKey}',
        // OpenRouter просит указывать источник запроса.
        'HTTP-Referer': 'https://github.com/shooting-app',
        'X-Title': 'Shooting App',
      };

  String _errorFrom(http.Response res) {
    try {
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is Map && data['error'] is Map) {
        return '${res.statusCode} ${data['error']['message']}';
      }
    } catch (_) {
      // тело не JSON — покажем как есть, ниже
    }
    return 'HTTP ${res.statusCode}';
  }

  /// Допустимые типы графика. Всё остальное — мусор, который в
  /// интерфейс пускать нельзя.
  static const Set<String> chartTypes = {'line', 'bar', 'table'};

  /// Отделяет блок ```chart от текста ответа.
  ///
  /// Берётся ПОСЛЕДНИЙ блок: если модель рассуждала вслух, она успевает
  /// набросать черновой график по дороге, и первый блок оказывается
  /// черновиком, а не итогом.
  ///
  /// Спецификация проверяется здесь же. Раньше проверки не было, и в
  /// интерфейс уезжал ответ модели, скопировавшей шаблон из промпта
  /// дословно (`"type":"line|bar|table"`), — пользователь видел нашу
  /// внутреннюю ошибку вместо графика. Теперь негодная спецификация
  /// молча отбрасывается, текст ответа остаётся.
  static (String, Map<String, dynamic>?) _splitChart(String raw) {
    final matches = RegExp(r'```chart\s*([\s\S]*?)```').allMatches(raw).toList();
    if (matches.isEmpty) return (raw, null);

    // Текст без всех chart-блоков.
    var text = raw;
    for (final m in matches.reversed) {
      text = text.replaceRange(m.start, m.end, '');
    }
    text = text.trim();

    try {
      final decoded = jsonDecode(matches.last.group(1)!.trim());
      if (decoded is Map<String, dynamic> &&
          chartTypes.contains('${decoded['type']}'.toLowerCase())) {
        return (text, decoded);
      }
    } catch (_) {
      // некорректный JSON — молча оставляем только текст
    }
    return (text, null);
  }

  /// Мишени, которые модель вправе называть в предложенном упражнении —
  /// тот же справочник, что и везде в приложении, а не выдуманные коды.
  static const Set<String> targetFaceCodes = {
    'rifle_10m',
    'pistol_10m',
    'rifle_50m',
    'pistol_25m',
  };

  static const Set<String> _genders = {'male', 'female', 'mixed'};

  /// Отделяет блок ```exercise (предложение упражнения) от текста.
  ///
  /// Тот же принцип, что у `_splitChart`: белый список проверяется в
  /// коде, а не только просьбой в промпте — модель, которую попросили
  /// "не выдумывай мишень", однажды её выдумает. Негодная спецификация
  /// молча отбрасывается, текст ответа остаётся как есть.
  static (String, Map<String, dynamic>?) _splitExercise(String raw) {
    final matches = RegExp(r'```exercise\s*([\s\S]*?)```').allMatches(raw).toList();
    if (matches.isEmpty) return (raw, null);

    var text = raw;
    for (final m in matches.reversed) {
      text = text.replaceRange(m.start, m.end, '');
    }
    text = text.trim();

    try {
      final decoded = jsonDecode(matches.last.group(1)!.trim());
      if (decoded is Map<String, dynamic> && _isValidExercise(decoded)) {
        return (text, decoded);
      }
    } catch (_) {
      // некорректный JSON — молча оставляем только текст
    }
    return (text, null);
  }

  static bool _isValidExercise(Map<String, dynamic> spec) {
    final name = spec['name'];
    if (name is! String || name.trim().isEmpty) return false;

    final face = spec['target_face_code'];
    if (face is! String || !targetFaceCodes.contains(face)) return false;

    final gender = spec['gender'];
    if (gender != null && !_genders.contains('$gender')) return false;

    final series = spec['series'];
    if (series != null) {
      if (series is! List || series.isEmpty) return false;
      for (final s in series) {
        if (s is! Map) return false;
        final sName = s['name'];
        if (sName is! String || sName.trim().isEmpty) return false;
        final shotCount = s['shot_count'];
        final timeLimitMin = s['time_limit_min'];
        final hasShots = shotCount is num && shotCount > 0;
        final hasTime = timeLimitMin is num && timeLimitMin > 0;
        // Ровно одна граница серии — как в SeriesSpec: и выстрелами, и
        // временем сразу серия ограничена быть не может.
        if (hasShots == hasTime) return false;
        final counts = s['counts'];
        if (counts != null && counts is! bool) return false;
      }
      return true;
    }

    // Без series — старый вид: обязательны total_shots и series_size.
    final totalShots = spec['total_shots'];
    final seriesSize = spec['series_size'];
    return totalShots is num && totalShots > 0 && seriesSize is num && seriesSize > 0;
  }

  /// Отделяет рассуждения модели от собственно ответа.
  ///
  /// Три случая, по убыванию надёжности:
  /// 1. Модель обернула размышления в `<think>…</think>`.
  /// 2. Модель выполнила инструкцию из промпта и поставила разделитель
  ///    `---ОТВЕТ---` перед финальным текстом.
  /// 3. Модель вывалила рассуждение в начало текста без разметки (так
  ///    делает, например, nemotron): опознаём по характерным зачинам.
  ///
  /// Если ничего не сработало — весь текст считается ответом. Потерять
  /// ответ хуже, чем показать лишнее.
  static (String, String?) splitReasoning(String raw) {
    final think = RegExp(r'<think>([\s\S]*?)</think>', caseSensitive: false).firstMatch(raw);
    if (think != null) {
      final text = raw.replaceRange(think.start, think.end, '').trim();
      return (text, think.group(1)!.trim());
    }

    final marker = RegExp(r'-{2,}\s*ОТВЕТ\s*-{2,}', caseSensitive: false);
    final markers = marker.allMatches(raw).toList();
    if (markers.isNotEmpty) {
      final last = markers.last;
      final head = raw.substring(0, last.start).trim();
      final tail = raw.substring(last.end).trim();
      if (tail.isNotEmpty) return (tail, head.isEmpty ? null : head);
    }

    final preamble = RegExp(
      r"^\s*(here'?s a thinking process|thinking process|let me think|okay,? let'?s|мысли|размышлени)",
      caseSensitive: false,
    );
    if (preamble.hasMatch(raw)) {
      // Текст начинается с размышления, а разделителя ---ОТВЕТ--- нет —
      // значит модель до ответа не добралась (обычно упёрлась в лимит
      // токенов). Раньше здесь брался последний абзац как «ответ», и
      // пользователь получал случайный кусок рассуждения. Теперь всё
      // уходит в рассуждения, ответ пустой — и вызывающий код перейдёт
      // к следующей модели.
      return ('', raw);
    }

    return (raw, null);
  }
}
