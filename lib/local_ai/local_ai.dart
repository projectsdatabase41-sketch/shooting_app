import 'dart:async';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import '../services/ai_settings.dart';
import 'local_ai_catalog.dart';
import 'local_ai_memory.dart';
import 'local_ai_platform.dart';

/// Один запрос к локальной модели — то же, что уходит в облако.
typedef LocalRequest = ({
  String modelPath,
  LocalModelInfo model,
  String system,
  List<({String role, String text})> history,
  bool json,
  Uint8List? image,
});

/// Локальная модель ИИ (llama.cpp через `llamadart`) — третий вариант
/// рядом со встроенным и своим ключом. Доступна всем (сначала была только
/// в режиме разработчика); удаляется папкой `lib/local_ai/`.
///
/// Режимы (`AiSettings.localMode`):
/// * `off` — как раньше, только облако;
/// * `tasks` — лёгкие служебные задачи ([lightTasks]) сначала локально,
///   ответ не прошёл проверку — тот же запрос уходит в облако;
/// * `all` — всё, включая чат ассистента, сначала локально (работает без
///   интернета; облако — только запасной путь).
class LocalAi {
  LocalAi._();
  static final LocalAi instance = LocalAi._();

  /// Подмена движка в тестах.
  static Future<String> Function(LocalRequest r)? debugGenerate;

  /// Задачи, где маленькой модели хватает (короткий проверяемый ответ).
  static const Set<String> lightTasks = {
    'chat_colors',
    'app_preset',
    'table_describe',
    'knowledge_columns',
    'service_display',
    'service_filter',
    'note_create',
    'note_edit',
  };

  // ponytail: окно 4096 токенов для всех моделей; поднять для 7B на ПК,
  // если в режиме `all` чату будет тесно.
  static const int _contextTokens = 4096;
  static const int _maxSystemChars = 6000;
  static const int _maxHistoryChars = 1500;
  static const int _maxHistoryMessages = 6;

  LlamaEngine? _engine;
  String? _loadedPath;
  bool _projectorLoaded = false;

  /// Просьба прервать текущую работу со снимком (назад / свернули приложение).
  bool _cancel = false;

  /// Прервать распознавание: загрузку модели оборвать нельзя, но
  /// генерация остановится, а ответ придёт ошибкой [LocalAiCancelled].
  void cancel() {
    _cancel = true;
    _engine?.cancelGeneration();
  }

  Future<void> _lock = Future.value();
  Timer? _idle;

  /// Установлен ли файл выбранной модели целиком.
  static Future<String?> installedPath(LocalModelInfo m) async {
    if (!localAiSupported) return null;
    final path = p.join(await modelsDir(), m.fileName);
    if (fileLength(path) != m.sizeBytes) return null;
    // У модели «со зрением» нужен и файл проектора.
    if (m.projector != null && await installedPath(m.projector!) == null) return null;
    return path;
  }

  bool wants(AiSettings s, String? task) {
    if (task == null || !localAiSupported) return false;
    return switch (s.localMode) {
      'all' => true,
      'tasks' => lightTasks.contains(task),
      _ => false,
    };
  }

  /// Пробует ответить локально. `null` — модели нет, сбой или ответ не
  /// прошёл [accept]: вызывающий код идёт в облако.
  Future<String?> tryRun(
    AiSettings s, {
    required String task,
    required String system,
    required List<({String role, String text})> history,
    required bool json,
    required bool Function(String text) accept,
  }) async {
    final model = localModelById(s.localModelId);
    if (model == null) return null;
    final path = debugGenerate != null ? 'test' : await installedPath(model);
    if (path == null) return null;

    final memory = LocalAiMemory(s.db);
    final input = '$system\n---\n${history.map((m) => '${m.role}: ${m.text}').join('\n')}';
    final hit = memory.cached(task, input);
    if (hit != null && accept(hit)) return hit;

    final lastUser = history.lastWhere((m) => m.role == 'user', orElse: () => (role: 'user', text: '')).text;
    final examples = task == 'chat' ? const <({String input, String output})>[] : memory.examples(task, lastUser);
    final sys = StringBuffer(system);
    if (examples.isNotEmpty) {
      sys.writeln('\n\nПРИМЕРЫ УДАЧНЫХ ОТВЕТОВ НА ПОХОЖИЕ ЗАПРОСЫ:');
      for (final e in examples) {
        sys.writeln('Запрос: ${e.input}\nОтвет: ${e.output}\n');
      }
    }
    final trimmedHistory = [
      for (final m in history.skip(history.length > _maxHistoryMessages ? history.length - _maxHistoryMessages : 0))
        (role: m.role, text: _clip(m.text, _maxHistoryChars)),
    ];
    final req = (
      modelPath: path,
      model: model,
      system: _clip(sys.toString(), _maxSystemChars),
      history: trimmedHistory,
      json: json,
      image: null,
    );
    try {
      final text = (await (debugGenerate ?? _generate)(req)).trim();
      if (text.isEmpty || !accept(text)) return null;
      memory.remember('cache', task, input, text);
      return text;
    } catch (_) {
      return null;
    }
  }

  /// Облако справилось с лёгкой задачей — запоминаем как пример для
  /// локальной модели.
  void learn(AiSettings s, String task, List<({String role, String text})> history, String output) {
    if (!lightTasks.contains(task)) return;
    final lastUser = history.lastWhere((m) => m.role == 'user', orElse: () => (role: 'user', text: '')).text;
    if (lastUser.isEmpty) return;
    try {
      LocalAiMemory(s.db).remember('example', task, lastUser, output);
    } catch (_) {}
  }

  /// Короткая проверка из настроек: ответ и скорость.
  Future<({String text, Duration took})> probe(LocalModelInfo model) async {
    final path = await installedPath(model);
    if (path == null) throw StateError('Модель не скачана');
    final sw = Stopwatch()..start();
    final text = await _generate((
      modelPath: path,
      model: model,
      system: 'Отвечай кратко, по-русски.',
      history: const [(role: 'user', text: 'Назови три упражнения для тренировки стрелка.')],
      json: false,
      image: null,
    ));
    return (text: text.trim(), took: sw.elapsed);
  }

  /// Одна генерация за раз (на телефоне две модели в памяти не поместятся);
  /// через 3 минуты простоя модель выгружается, освобождая ОЗУ.
  Future<String> _generate(LocalRequest r) {
    final done = Completer<String>();
    _lock = _lock.then((_) async {
      _idle?.cancel();
      try {
        if (_engine == null || _loadedPath != r.modelPath) {
          await _engine?.dispose();
          _engine = null;
          _projectorLoaded = false;
          final e = LlamaEngine(LlamaBackend());
          // Процессор, не видеокарта: на встроенной графике (проверено на
          // Intel N95 + UHD) Vulkan в 2–5 раз медленнее.
          // ponytail: переключатель «видеокарта» — когда будет мощное железо проверить.
          await e.loadModel(r.modelPath, modelParams: const ModelParams(contextSize: _contextTokens, gpuLayers: 0));
          _engine = e;
          _loadedPath = r.modelPath;
        }
        if (r.image != null && _cancel) throw const LocalAiCancelled();
        // Зрение подгружается только когда пришла картинка — для текста не нужно.
        if (r.image != null && !_projectorLoaded) {
          await _engine!.loadMultimodalProjector(p.join(await modelsDir(), r.model.projector!.fileName));
          _projectorLoaded = true;
        }
        final out = StringBuffer();
        await for (final chunk in _engine!.create(
          [
            if (r.system.isNotEmpty) LlamaChatMessage.fromText(role: LlamaChatRole.system, text: r.system),
            for (final (i, m) in r.history.indexed)
              r.image != null && i == r.history.length - 1
                  ? LlamaChatMessage.withContent(role: LlamaChatRole.user, content: [
                      LlamaImageContent(bytes: r.image),
                      LlamaTextContent(m.text),
                    ])
                  : LlamaChatMessage.fromText(
                      role: m.role == 'assistant' ? LlamaChatRole.assistant : LlamaChatRole.user,
                      text: m.text,
                    ),
          ],
          params: const GenerationParams(maxTokens: 1024, temp: 0.2),
          enableThinking: false,
          responseFormat: r.json ? const {'type': 'json_object'} : null,
        )) {
          if (r.image != null && _cancel) break;
          if (chunk.choices.isEmpty) continue;
          final t = chunk.choices.first.delta.content;
          if (t != null) out.write(t);
        }
        if (r.image != null && _cancel) throw const LocalAiCancelled();
        done.complete(out.toString());
      } catch (e, st) {
        done.completeError(e, st);
      } finally {
        _idle = Timer(const Duration(minutes: 3), unload);
      }
    });
    return done.future;
  }

  /// Вопрос по картинке к выбранной модели «со зрением» (поиск пробоин).
  Future<String> see(LocalModelInfo model, Uint8List image, String prompt) async {
    final path = await installedPath(model);
    if (path == null || !model.sees) throw StateError('Модель со зрением не скачана');
    _cancel = false;
    return _generate((
      modelPath: path,
      model: model,
      system: '',
      history: [(role: 'user', text: prompt)],
      json: false,
      image: image,
    ));
  }

  Future<void> unload() async {
    _idle?.cancel();
    final e = _engine;
    _engine = null;
    _loadedPath = null;
    _projectorLoaded = false;
    await e?.dispose();
  }

  static String _clip(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';
}

/// Распознавание прервали (назад / свернули приложение).
class LocalAiCancelled implements Exception {
  const LocalAiCancelled();
  @override
  String toString() => 'Распознавание прервано';
}
