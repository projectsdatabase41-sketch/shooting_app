import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import '../services/ai_settings.dart';
import 'local_ai.dart';
import 'local_ai_catalog.dart';
import 'local_ai_platform.dart';

/// Поиск пробоин на фото мишени выбранной локальной моделью «со зрением»
/// (режим разработчика). Отдельной модели нет: та же, что отвечает в
/// диалогах, если у неё есть проектор изображений (`LocalModelInfo.sees`).
class LocalVision {
  LocalVision._();

  /// Сторона квадрата, который уходит в модель. Кратно 28 (патч Qwen2.5-VL)
  /// и не больше её предела — llama.cpp не перемасштабирует, и координаты
  /// из ответа остаются в этой же сетке.
  static const int side = 896;

  static bool _devMode(AiSettings s) {
    final rows = s.db.db.select("SELECT hex FROM color_prefs WHERE key = 'dev_mode_enabled'");
    return rows.isNotEmpty && rows.first['hex'] == '1';
  }

  /// Выбранная локальная модель, если она видит фото и скачана; иначе null.
  static Future<LocalModelInfo?> active(AiSettings s) async {
    if (!localAiSupported || !_devMode(s)) return null;
    final m = localModelById(s.localModelId);
    if (m == null || !m.sees || await LocalAi.installedPath(m) == null) return null;
    return m;
  }

  /// Центры пробоин на квадратном снимке [jpeg] стороной [side] — в его же
  /// пикселях. Пусто — модель ничего не нашла.
  static Future<List<Offset>> findHoles(LocalModelInfo m, Uint8List jpeg) async =>
      parseHolePoints(await LocalAi.instance.see(m, jpeg, prompt), side.toDouble());

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
