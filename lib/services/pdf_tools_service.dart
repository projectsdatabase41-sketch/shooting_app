import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'call_service.dart';
import 'chat_auth_service.dart';

/// PDF-инструменты через наш сервер звонков (iLoveAPI).
///
/// Ключ проекта iLoveAPI живёт в секретах воркера, приложение его не знает.
/// Файл уходит на сервер, там же выполняется задача (объединить, разделить,
/// сжать, конвертировать и т.д.), результат возвращается тем же путём.
/// Пока ключ не задан, сервер отвечает 503, и [notConfigured] становится
/// `true` — интерфейс показывает «модуль не настроен».
class PdfToolsService {
  PdfToolsService(this.auth);

  final ChatAuthService auth;

  /// Последний вызов упёрся в отсутствие ключа на сервере.
  static bool notConfigured = false;

  static const tools = <String, String>{
    'merge': 'Объединить PDF',
    'split': 'Разделить PDF',
    'compress': 'Сжать PDF',
    'officepdf': 'Office → PDF',
    'htmlpdf': 'HTML → PDF',
    'imagepdf': 'Изображения → PDF',
    'pdfjpg': 'PDF → JPG',
    'pdfa': 'PDF/A',
    'pagenumber': 'Номера страниц',
    'watermark': 'Водяной знак',
    'rotate': 'Повернуть страницы',
    'repair': 'Восстановить PDF',
    'protect': 'Защитить паролем',
    'unlock': 'Снять пароль',
    'validate': 'Проверить PDF',
    'unpack': 'Извлечь вложения',
    'splitsmart': 'Разделить по содержимому',
    'editpdf': 'Редактировать PDF',
    'ocr': 'Распознать текст (OCR)',
  };

  /// Инструменты, которым нужен ровно один файл.
  static const singleFileTools = {
    'split', 'compress', 'pdfjpg', 'pdfa', 'pagenumber', 'watermark', 'rotate',
    'repair', 'protect', 'unlock', 'validate', 'unpack', 'splitsmart',
    'editpdf', 'ocr',
  };

  Future<String?> _token() => auth.ensureFreshToken();

  /// Загружает файл на сервер. Возвращает идентификатор загрузки.
  Future<({String id, String name})?> upload(Uint8List bytes, String name) async {
    final token = await _token();
    if (token == null) return null;
    final client = http.Client();
    try {
      final res = await client
          .post(
            Uri.parse('${CallService.url}/pdf/upload'),
            headers: {
              'Authorization': 'Bearer $token',
              'x-file-name': name,
              'content-type': 'application/octet-stream',
            },
            body: bytes,
          )
          .timeout(const Duration(minutes: 2));
      if (res.statusCode != 200) return null;
      final id = _field(res.bodyBytes, 'id');
      return id == null ? null : (id: id, name: name);
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Выполняет задачу. Возвращает идентификатор результата.
  Future<String?> run(
    String tool,
    List<({String id, String name})> files, {
    Map<String, dynamic>? options,
  }) async {
    final token = await _token();
    if (token == null) return null;
    final client = http.Client();
    try {
      final res = await client
          .post(
            Uri.parse('${CallService.url}/pdf/run'),
            headers: {'Authorization': 'Bearer $token', 'content-type': 'application/json'},
            body: _json({
              'tool': tool,
              'files': [for (final f in files) {'id': f.id, 'name': f.name}],
              if (options != null) 'options': options,
            }),
          )
          .timeout(const Duration(minutes: 3));
      if (res.statusCode == 503) {
        notConfigured = true;
        return null;
      }
      notConfigured = false;
      if (res.statusCode != 200) return null;
      return _field(res.bodyBytes, 'id');
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Скачивает готовый файл.
  Future<Uint8List?> download(String id) async {
    final token = await _token();
    if (token == null) return null;
    final client = http.Client();
    try {
      final res = await client.get(
        Uri.parse('${CallService.url}/pdf/result/$id'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(minutes: 2));
      if (res.statusCode != 200) return null;
      return res.bodyBytes;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  // Минимальный разбор JSON без лишних зависимостей: ответы короткие.
  static String? _field(Uint8List body, String key) {
    final text = String.fromCharCodes(body);
    final m = RegExp('"$key"\\s*:\\s*"([^"]+)"').firstMatch(text);
    return m?.group(1);
  }

  static String _json(Map<String, dynamic> map) {
    final parts = <String>[];
    map.forEach((k, v) {
      final value = v is String
          ? '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"'
          : v is List
              ? '[${v.map((e) => e is Map ? _json(e.cast<String, dynamic>()) : '"$e"').join(',')}]'
              : v is Map
                  ? _json(v.cast<String, dynamic>())
                  : '$v';
      parts.add('"$k":$value');
    });
    return '{${parts.join(',')}}';
  }
}
