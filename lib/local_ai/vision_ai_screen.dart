import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/ai_settings.dart';
import 'local_ai_catalog.dart';
import 'local_ai_platform.dart';
import 'local_vision.dart';

/// Загрузки переживают экран: закрыли настройки — качается дальше.
final Map<String, ValueNotifier<double>> _progress = {};

/// «Распознавание фото» (режим разработчика) — отдельно от текстовой
/// локальной модели: своя модель со «зрением», она ищет пробоины на
/// фото мишени (экран «Фото мишени»).
class VisionAiScreen extends StatefulWidget {
  final AiSettings settings;
  const VisionAiScreen({super.key, required this.settings});

  @override
  State<VisionAiScreen> createState() => _VisionAiScreenState();
}

class _VisionAiScreenState extends State<VisionAiScreen> {
  AiSettings get s => widget.settings;
  final Map<String, bool> _installed = {};
  double? _ramGb;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!localAiSupported) return;
    final ram = await totalRamBytes();
    for (final m in visionModelCatalog) {
      _installed[m.id] = await LocalVision.installed(m);
      if (_installed[m.id] != true && !_progress.containsKey(m.id)) {
        for (final f in [m.model, m.projector]) {
          if (await modelDownloadActive(f.id)) {
            _download(m);
            break;
          }
        }
      }
    }
    if (mounted) setState(() => _ramGb = ram == null ? null : ram / (1 << 30));
  }

  static String _gb(int bytes) => '${(bytes / 1e9).toStringAsFixed(bytes < 1e9 ? 2 : 1)} ГБ';

  Future<void> _confirmDownload(VisionModelInfo m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Скачать ${m.name}?'),
        content: Text('Два файла, всего ${_gb(m.sizeBytes)} с huggingface.co. Лучше по Wi-Fi.\n\n'
            'Качается в фоне с уведомлением; пауза продолжится с того же места.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Скачать')),
        ],
      ),
    );
    if (ok == true) _download(m);
  }

  /// Модель и проектор по очереди; прогресс — общий по байтам.
  Future<void> _download(VisionModelInfo m) async {
    final note = _progress[m.id] = ValueNotifier(0);
    if (mounted) setState(() {});
    final messenger = ScaffoldMessenger.of(context);
    try {
      var doneBytes = 0;
      for (final f in [m.model, m.projector]) {
        final path = p.join(await modelsDir(), f.fileName);
        if (fileLength(path) != f.sizeBytes) {
          await downloadModel(
            id: f.id,
            url: f.url,
            fileName: f.fileName,
            displayName: '${m.name} (${f == m.model ? 'модель' : 'зрение'})',
            onProgress: (v) => note.value = (doneBytes + v * f.sizeBytes) / m.sizeBytes,
          );
          note.value = -1;
          if (await sha256OfFile(path) != f.sha256) {
            await deleteFile(path);
            throw Exception('файл повреждён при загрузке, скачайте ещё раз');
          }
        }
        doneBytes += f.sizeBytes;
      }
      if (s.visionModelId.isEmpty) s.visionModelId = m.id;
      messenger.showSnackBar(SnackBar(content: Text('${m.name} установлена')));
    } on DownloadCancelled {
      messenger.showSnackBar(const SnackBar(content: Text('Загрузка приостановлена')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Не удалось скачать: $e')));
    } finally {
      _progress.remove(m.id);
      await _refresh();
    }
  }

  Future<void> _pause(VisionModelInfo m) async {
    await pauseModelDownload(m.model.id);
    await pauseModelDownload(m.projector.id);
  }

  Future<void> _delete(VisionModelInfo m) async {
    await LocalVision.instance.unload();
    for (final LocalModelInfo f in [m.model, m.projector]) {
      await deleteFile(p.join(await modelsDir(), f.fileName));
    }
    if (s.visionModelId == m.id) s.visionModelId = '';
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!localAiSupported) {
      return Scaffold(
        appBar: AppBar(title: const Text('Распознавание фото')),
        body: const Padding(
          padding: EdgeInsets.all(24),
          child: Text('В браузере распознавание не работает — только в приложении для Android и Windows.'),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Распознавание фото')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            'Модель со «зрением» прямо на устройстве: ищет пробоины на фото мишени и не путает их с цифрами '
            'колец. Круг мишени по-прежнему находится автоматически и правится руками, найденные точки '
            'вы подтверждаете. Отдельно от текстовой локальной модели.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text('Память устройства: ${_ramGb == null ? 'неизвестно' : '${_ramGb!.toStringAsFixed(1)} ГБ'}',
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          for (final m in visionModelCatalog) _tile(m),
          const SizedBox(height: 8),
          Text(
            s.visionModelId.isEmpty
                ? 'Модель не выбрана — на фото работает обычный алгоритм.'
                : 'На экране «Фото мишени» пробоины ищет выбранная модель.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _tile(VisionModelInfo m) {
    final theme = Theme.of(context);
    final installed = _installed[m.id] == true;
    final selected = s.visionModelId == m.id;
    final progress = _progress[m.id];
    final tooHeavy = _ramGb != null && _ramGb! + 0.5 < m.minRamGb;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (installed)
                  IconButton(
                    tooltip: selected ? 'Выключить' : 'Использовать',
                    icon: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                    onPressed: () => setState(() => s.visionModelId = selected ? '' : m.id),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.name, style: theme.textTheme.titleSmall),
                      Text('${_gb(m.sizeBytes)} · от ${m.minRamGb} ГБ ОЗУ', style: theme.textTheme.bodySmall),
                      Text(m.note, style: theme.textTheme.bodySmall),
                      if (tooHeavy)
                        Text('Может не потянуть: мало памяти',
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                    ],
                  ),
                ),
                if (progress == null && !installed)
                  IconButton(
                      tooltip: 'Скачать',
                      icon: const Icon(Icons.download_outlined),
                      onPressed: () => _confirmDownload(m)),
                if (progress != null)
                  IconButton(
                      tooltip: 'Приостановить', icon: const Icon(Icons.pause_outlined), onPressed: () => _pause(m)),
                if (installed)
                  IconButton(tooltip: 'Удалить', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(m)),
              ],
            ),
            if (progress != null)
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (_, v, __) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(value: v < 0 ? null : v),
                    Text(v < 0 ? 'Проверка файла…' : '${(v * 100).toStringAsFixed(0)}%',
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
