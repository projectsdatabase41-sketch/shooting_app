// ignore_for_file: avoid_print
// Словари перевода интерфейса (lib/i18n/i18n.dart).
//
//   dart run tool/i18n.dart          — собрать строки tr('…') из lib/, убрать
//                                      из словарей удалённые, показать, чего
//                                      не хватает;
//   OPENROUTER_KEY=… dart run tool/i18n.dart --translate
//                                    — ещё и перевести недостающее через ИИ.
//
// Встроенные языки — assets/i18n/<код>.json, скачиваемые — i18n/<код>.json.
// Ключ — русский текст; {подстановки} переводчик обязан оставить как есть.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const builtIn = ['en', 'de', 'zh'];
const downloadable = ['es', 'fr', 'it', 'pt', 'pl', 'uk', 'kk', 'tr', 'ja', 'ko'];
const languageNames = {
  'en': 'English',
  'de': 'German',
  'zh': 'Simplified Chinese',
  'es': 'Spanish',
  'fr': 'French',
  'it': 'Italian',
  'pt': 'Portuguese',
  'pl': 'Polish',
  'uk': 'Ukrainian',
  'kk': 'Kazakh',
  'tr': 'Turkish',
  'ja': 'Japanese',
  'ko': 'Korean',
};

/// tr('…') с одинарными кавычками; строка может быть склеена из соседних
/// литералов: tr('а ' 'б'). Строки в константах, которые переводятся при
/// показе, помечены так: label: /*tr*/ 'Мишень'.
final _call = RegExp(r"""(?:\btr\(|/\*tr\*/)\s*((?:'(?:[^'\\]|\\.)*'\s*)+)""");
final _literal = RegExp(r"""'((?:[^'\\]|\\.)*)'""");

String _unescape(String s) => s.replaceAllMapped(RegExp(r'\\(.)'), (m) => switch (m[1]) {
      'n' => '\n',
      't' => '\t',
      _ => m[1]!,
    });

Set<String> extractKeys(String source) => {
      for (final m in _call.allMatches(source)) _literal.allMatches(m[1]!).map((l) => _unescape(l[1]!)).join(),
    };

Future<void> main(List<String> args) async {
  final translate = args.contains('--translate');
  final keys = <String>{};
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
    if (f.path.endsWith('.dart')) keys.addAll(extractKeys(f.readAsStringSync()));
  }
  print('Строк в коде: ${keys.length}');

  final apiKey = Platform.environment['OPENROUTER_KEY'] ?? '';
  for (final code in [...builtIn, ...downloadable]) {
    final file = File(builtIn.contains(code) ? 'assets/i18n/$code.json' : 'i18n/$code.json');
    final dict = file.existsSync()
        ? Map<String, String>.from(jsonDecode(file.readAsStringSync()) as Map)
        : <String, String>{};
    dict.removeWhere((k, _) => !keys.contains(k));
    final missing = keys.where((k) => !dict.containsKey(k)).toList()..sort();
    if (missing.isNotEmpty && translate) {
      if (apiKey.isEmpty) {
        print('Нет OPENROUTER_KEY — перевести нечем');
        exit(1);
      }
      for (var i = 0; i < missing.length; i += 40) {
        final batch = missing.sublist(i, i + 40 > missing.length ? missing.length : i + 40);
        dict.addAll(await _translateAny(apiKey, code, batch));
      }
    }
    final left = keys.where((k) => !dict.containsKey(k)).length;
    print('$code: ${dict.length} переведено, не хватает $left');
    if (dict.isEmpty && !file.existsSync()) continue;
    file.parent.createSync(recursive: true);
    final sorted = Map.fromEntries(dict.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(sorted)}\n');
  }
}

/// Модели для перевода: I18N_MODELS (через запятую) или бесплатные модели
/// из того же списка, что и у приложения (lib/services/ai_settings.dart) —
/// бесплатные на OpenRouter меняются, а этот список и так поддерживается.
List<String> _models() {
  final env = Platform.environment['I18N_MODELS'] ?? '';
  if (env.trim().isNotEmpty) return env.split(',').map((m) => m.trim()).where((m) => m.isNotEmpty).toList();
  final src = File('lib/services/ai_settings.dart').readAsStringSync();
  return RegExp(r"'([\w.\-]+/[\w.\-]+:free)'").allMatches(src).map((m) => m[1]!).toSet().toList();
}

/// Пробует модели по очереди, пока одна не переведёт пачку. Не вышло ни у
/// одной — пачка останется русской до следующего запуска.
Future<Map<String, String>> _translateAny(String apiKey, String code, List<String> batch) async {
  for (final model in _models()) {
    try {
      final out = await _translate(apiKey, model, code, batch);
      if (out.length >= batch.length * 0.8) return out;
      print('  $model: переведено мало (${out.length}/${batch.length}), пробую следующую');
    } catch (e) {
      print('  $model: $e');
    }
  }
  return const {};
}

/// Пачка строк → JSON {русский: перевод}. Ответ без нужных ключей или с
/// потерянными {подстановками} отбрасывается — строка останется русской.
Future<Map<String, String>> _translate(String apiKey, String model, String code, List<String> batch) async {
  final res = await http.post(
    Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
    headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'},
    body: jsonEncode({
      'model': model,
      'response_format': {'type': 'json_object'},
      'messages': [
        {
          'role': 'system',
          'content': 'You translate the user interface of a sports shooting training app (ISSF rifle and pistol, '
              'targets, series, shots, coach, athlete, messenger) from Russian to ${languageNames[code]}. '
              'Answer with ONE JSON object mapping each Russian string exactly as given to its translation. '
              'Keep placeholders like {n} or {name} unchanged, keep line breaks, keep it short like UI text, '
              'use standard ISSF shooting terminology.',
        },
        {'role': 'user', 'content': jsonEncode(batch)},
      ],
    }),
  ).timeout(const Duration(minutes: 3));
  if (res.statusCode != 200) throw Exception('OpenRouter ${res.statusCode}: ${res.body}');
  final content = (jsonDecode(utf8.decode(res.bodyBytes))['choices'][0]['message']['content'] as String).trim();
  final decoded = jsonDecode(content.substring(content.indexOf('{'), content.lastIndexOf('}') + 1)) as Map;
  final out = <String, String>{};
  final placeholder = RegExp(r'\{\w+\}');
  for (final k in batch) {
    final v = decoded[k];
    // Пустой перевод допустим только у окончаний вроде «ь» в «модел{p}».
    if (v is! String || (v.trim().isEmpty && k.length > 2)) continue;
    final need = placeholder.allMatches(k).map((m) => m[0]!).toSet();
    if (!need.every((p) => v.contains(p))) continue;
    out[k] = v;
  }
  return out;
}
