import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import '../services/ai_settings.dart';
import 'local_ai.dart';
import 'local_ai_catalog.dart';
import 'local_ai_platform.dart';

/// Модель «со зрением»: сама модель + проектор изображений (оба GGUF).
class VisionModelInfo {
  final String id;
  final String name;
  final String note;
  final int minRamGb;
  final LocalModelInfo model;
  final LocalModelInfo projector;
  const VisionModelInfo({
    required this.id,
    required this.name,
    required this.note,
    required this.minRamGb,
    required this.model,
    required this.projector,
  });

  int get sizeBytes => model.sizeBytes + projector.sizeBytes;
}

LocalModelInfo _file(String id, String repo, String file, int size, String sha) => LocalModelInfo(
      id: id,
      name: file,
      tier: '',
      note: '',
      url: 'https://huggingface.co/$repo/resolve/main/$file',
      sizeBytes: size,
      sha256: sha,
      minRamGb: 0,
    );

/// ponytail: две модели в коде; каталог в удалённый конфиг — когда появятся лучше.
final List<VisionModelInfo> visionModelCatalog = [
  VisionModelInfo(
    id: 'qwen2.5-vl-3b',
    name: 'Qwen2.5-VL 3B',
    note: 'Точнее: обучена указывать координаты предметов на фото. Хороший телефон или ПК',
    minRamGb: 6,
    model: _file('vision-qwen2.5-vl-3b', 'ggml-org/Qwen2.5-VL-3B-Instruct-GGUF', 'Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf',
        1929901056, 'd02fe9b69ad8cadbbd228e387667af66612c44bed29ffc8eb1e7caf9ac486c12'),
    projector: _file(
        'vision-qwen2.5-vl-3b-mmproj',
        'ggml-org/Qwen2.5-VL-3B-Instruct-GGUF',
        'mmproj-Qwen2.5-VL-3B-Instruct-Q8_0.gguf',
        844757728,
        '980c9b2f78c04e6cff93d277ada09e768394f112d75db3b4e9dea8a69f9fb904'),
  ),
  VisionModelInfo(
    id: 'smolvlm-500m',
    name: 'SmolVLM 500M',
    note: 'Лёгкая, любой телефон. Координаты грубые — для проверки идеи',
    minRamGb: 3,
    model: _file('vision-smolvlm-500m', 'ggml-org/SmolVLM-500M-Instruct-GGUF', 'SmolVLM-500M-Instruct-Q8_0.gguf',
        436806912, '9d4612de6a42214499e301494a3ecc2be0abdd9de44e663bda63f1152fad1bf4'),
    projector: _file(
        'vision-smolvlm-500m-mmproj',
        'ggml-org/SmolVLM-500M-Instruct-GGUF',
        'mmproj-SmolVLM-500M-Instruct-Q8_0.gguf',
        108783360,
        'd1eb8b6b23979205fdf63703ed10f788131a3f812c7b1f72e0119d5d81295150'),
  ),
];

VisionModelInfo? visionModelById(String id) {
  for (final m in visionModelCatalog) {
    if (m.id == id) return m;
  }
  return null;
}

/// Распознавание пробоин на фото локальной моделью со «зрением» (режим
/// разработчика, настройки ИИ → «Распознавание фото»). Отдельно от
/// текстовой локальной модели; перед загрузкой та выгружается — две в
/// памяти телефона не поместятся.
class LocalVision {
  LocalVision._();
  static final LocalVision instance = LocalVision._();

  /// Сторона квадрата, который уходит в модель. Кратно 28 (патч Qwen2.5-VL)
  /// и не больше её предела — llama.cpp не станет перемасштабировать, и
  /// координаты из ответа остаются в этой же сетке.
  static const int side = 896;

  LlamaEngine? _engine;
  String? _loadedId;
  Future<void> _lock = Future.value();
  Timer? _idle;

  static bool _devMode(AiSettings s) {
    final rows = s.db.db.select("SELECT hex FROM color_prefs WHERE key = 'dev_mode_enabled'");
    return rows.isNotEmpty && rows.first['hex'] == '1';
  }

  static Future<bool> installed(VisionModelInfo m) async =>
      await LocalAi.installedPath(m.model) != null && await LocalAi.installedPath(m.projector) != null;

  /// Выбранная и скачанная модель, если распознавание доступно; иначе null.
  static Future<VisionModelInfo?> active(AiSettings s) async {
    if (!localAiSupported || !_devMode(s)) return null;
    final m = visionModelById(s.visionModelId);
    if (m == null || !await installed(m)) return null;
    return m;
  }

  /// Центры пробоин на квадратном снимке [jpeg] стороной [side] — в его же
  /// пикселях. Пусто — модель ничего не нашла.
  Future<List<Offset>> findHoles(VisionModelInfo m, Uint8List jpeg) async {
    final text = await _generate(m, jpeg);
    return parseHolePoints(text, side.toDouble());
  }

  Future<String> _generate(VisionModelInfo m, Uint8List jpeg) {
    final done = Completer<String>();
    _lock = _lock.then((_) async {
      _idle?.cancel();
      try {
        if (_engine == null || _loadedId != m.id) {
          await LocalAi.instance.unload();
          await _engine?.dispose();
          _engine = null;
          final dir = await modelsDir();
          final e = LlamaEngine(LlamaBackend());
          await e.loadModel(p.join(dir, m.model.fileName),
              modelParams: const ModelParams(contextSize: 4096, gpuLayers: 0));
          await e.loadMultimodalProjector(p.join(dir, m.projector.fileName));
          _engine = e;
          _loadedId = m.id;
        }
        final out = StringBuffer();
        await for (final chunk in _engine!.create(
          [
            LlamaChatMessage.withContent(role: LlamaChatRole.user, content: [
              LlamaImageContent(bytes: jpeg, width: side, height: side),
              const LlamaTextContent(prompt),
            ]),
          ],
          params: const GenerationParams(maxTokens: 1024, temp: 0.1),
          enableThinking: false,
        )) {
          if (chunk.choices.isEmpty) continue;
          final t = chunk.choices.first.delta.content;
          if (t != null) out.write(t);
        }
        done.complete(out.toString());
      } catch (e, st) {
        done.completeError(e, st);
      } finally {
        _idle = Timer(const Duration(minutes: 3), unload);
      }
    });
    return done.future;
  }

  Future<void> unload() async {
    _idle?.cancel();
    final e = _engine;
    _engine = null;
    _loadedId = null;
    await e?.dispose();
  }

  static const String prompt = 'This is a photo of a paper shooting target ($side x $side pixels). '
      'Find every bullet hole: a small round hole punched through the paper, usually with a torn edge. '
      'Do NOT mark printed ring numbers, ring lines, the black aiming circle itself or dirt. '
      'Answer ONLY with JSON: [{"x": <pixel x of the hole centre>, "y": <pixel y>}, ...] '
      'in pixels of this image. If there are no holes, answer [].';
}

/// Точки из ответа модели. Понимает JSON `[{"x":..,"y":..}]`, рамки
/// Qwen `{"bbox_2d":[x1,y1,x2,y2]}` (берётся центр) и пары чисел в тексте.
/// Точки вне снимка отбрасываются, дубликаты ближе 1% стороны — тоже.
List<Offset> parseHolePoints(String text, double side) {
  final points = <Offset>[];
  void add(double x, double y) {
    if (x < 0 || y < 0 || x > side || y > side) return;
    final p = Offset(x, y);
    if (points.any((q) => (q - p).distance < side * 0.01)) return;
    points.add(p);
  }

  final start = text.indexOf('[');
  final end = text.lastIndexOf(']');
  if (start >= 0 && end > start) {
    try {
      final decoded = jsonDecode(text.substring(start, end + 1));
      if (decoded is List) {
        for (final e in decoded) {
          if (e is Map && e['x'] is num && e['y'] is num) {
            add((e['x'] as num).toDouble(), (e['y'] as num).toDouble());
          } else if (e is Map && e['bbox_2d'] is List && (e['bbox_2d'] as List).length == 4) {
            final b = [for (final v in e['bbox_2d'] as List) (v as num).toDouble()];
            add((b[0] + b[2]) / 2, (b[1] + b[3]) / 2);
          } else if (e is Map && e['point_2d'] is List && (e['point_2d'] as List).length == 2) {
            final b = [for (final v in e['point_2d'] as List) (v as num).toDouble()];
            add(b[0], b[1]);
          } else if (e is List && e.length == 2 && e[0] is num && e[1] is num) {
            add((e[0] as num).toDouble(), (e[1] as num).toDouble());
          }
        }
        return points;
      }
    } catch (_) {
      // не JSON — ниже разбор пар чисел
    }
  }
  for (final m in RegExp(r'(\d+(?:\.\d+)?)\s*[,;]\s*(\d+(?:\.\d+)?)').allMatches(text)) {
    add(double.parse(m.group(1)!), double.parse(m.group(2)!));
  }
  return points;
}
