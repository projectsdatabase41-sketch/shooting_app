// ignore_for_file: avoid_print
// Ручная проверка локальной модели: dart run tool/local_ai_probe.dart <модель.gguf>
import 'dart:convert';

import 'package:llamadart/llamadart.dart';

Future<void> main(List<String> args) async {
  final engine = LlamaEngine(LlamaBackend());
  final sw = Stopwatch()..start();
  await engine.loadModel(args.first, modelParams: ModelParams(contextSize: 4096, gpuLayers: args.length > 1 ? 0 : ModelParams.maxGpuLayers));
  final loaded = sw.elapsedMilliseconds;
  for (final (json, q) in [
    (true, 'Сегодня Ваня хорошо держал хват, но дёргал спуск. Верни JSON {"topic": "...", "content": "..."}.'),
    (false, 'Опиши одной фразой таблицу с колонками: date, shots, score, weather.'),
  ]) {
    final t0 = sw.elapsedMilliseconds;
    final out = StringBuffer();
    var tokens = 0;
    await for (final c in engine.create(
      [
        const LlamaChatMessage.fromText(role: LlamaChatRole.system, text: 'Ты помогаешь тренеру по стрельбе. Отвечай по-русски.'),
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: q),
      ],
      params: const GenerationParams(maxTokens: 200, temp: 0.2),
      enableThinking: false,
      responseFormat: json ? const {'type': 'json_object'} : null,
    )) {
      if (c.choices.isNotEmpty && c.choices.first.delta.content != null) {
        out.write(c.choices.first.delta.content);
        tokens++;
      }
    }
    final ms = sw.elapsedMilliseconds - t0;
    print('--- json=$json: $ms мс, ~${(tokens * 1000 / ms).toStringAsFixed(1)} ток/с\n$out');
    if (json) print('JSON валиден: ${(() { try { jsonDecode(out.toString()); return true; } catch (_) { return false; } })()}');
  }
  print('загрузка модели: $loaded мс; бэкенд: ${await engine.getBackendName()}');
  await engine.dispose();
}
