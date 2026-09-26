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
/// литералов: tr('а ' 'б').
final _call = RegExp(r"""\btr\(\s*((?:'(?:[^'\\]|\\.)*'\s*)+)""");
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
      for (var i = 0; i < missing.length; i += 60) {
        final batch = missing.sublist(i, i + 60 > missing.length ? missing.length : i + 60);
        dict.addAll(await _translate(apiKey, code, batch));
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

/// Пачка строк → JSON {русский: перевод}. Ответ без нужных ключей или с
/// потерянными {подстановками} отбрасывается — строка останется русской.
Future<Map<String, String>> _translate(String apiKey, String code, List<String> batch) async {
  final res = await http.post(
    Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
    headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'},
    body: jsonEncode({
      'model': 'google/gemini-2.5-flash',
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
  );
  if (res.statusCode != 200) throw Exception('OpenRouter ${res.statusCode}: ${res.body}');
  final content = (jsonDecode(utf8.decode(res.bodyBytes))['choices'][0]['message']['content'] as String).trim();
  final decoded = jsonDecode(content.substring(content.indexOf('{'), content.lastIndexOf('}') + 1)) as Map;
  final out = <String, String>{};
  final placeholder = RegExp(r'\{\w+\}');
  for (final k in batch) {
    final v = decoded[k];
    if (v is! String || v.trim().isEmpty) continue;
    final need = placeholder.allMatches(k).map((m) => m[0]!).toSet();
    if (!need.every((p) => v.contains(p))) continue;
    out[k] = v;
  }
  return out;
}
