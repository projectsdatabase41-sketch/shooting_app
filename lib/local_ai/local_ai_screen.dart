import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/ai_settings.dart';
import 'local_ai.dart';
import 'local_ai_catalog.dart';
import 'local_ai_memory.dart';
import 'local_ai_platform.dart';
import '../i18n/i18n.dart';

/// Идущие загрузки живут дольше экрана: закрыли настройки — качается дальше.
class _Downloads {
  static final Map<String, ValueNotifier<double>> progress = {};

  /// Какой файл сейчас качается: «Файл 1 из 2 (модель)» — у моделей со зрением
  /// их два, и общий процент прыгал (после первого файла начинался с 70%).
  static final Map<String, String> stage = {};
}

/// Настройки локальной модели: режим работы, выбор и
/// скачивание модели под мощность устройства, проверка, память.
class LocalAiScreen extends StatefulWidget {
  final AiSettings settings;
  const LocalAiScreen({super.key, required this.settings});

  @override
  State<LocalAiScreen> createState() => _LocalAiScreenState();
}

class _LocalAiScreenState extends State<LocalAiScreen> {
  AiSettings get s => widget.settings;
  int? _ramBytes;
  int? _freeBytes;
  final Map<String, bool> _installed = {};
  String? _probe;
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!localAiSupported) return;
    final ram = await totalRamBytes();
    final free = await freeDiskBytes(await modelsDir());
    for (final m in localModelCatalog) {
      _installed[m.id] = await LocalAi.installedPath(m) != null;
      // Загрузка шла, пока экран был закрыт (или приложение перезапускали)
      // — подключаемся к ней, чтобы снова показать прогресс.
      if (_installed[m.id] != true &&
          !_Downloads.progress.containsKey(m.id) &&
          (await modelDownloadActive(m.id) || (m.projector != null && await modelDownloadActive(m.projector!.id)))) {
        _resume(m);
      }
    }
    if (mounted) {
      setState(() {
        _ramBytes = ram;
        _freeBytes = free;
      });
    }
  }

  double? get _ramGb => _ramBytes == null ? null : _ramBytes! / (1 << 30);

  /// Самая крупная модель, которой хватает памяти (с запасом на систему).
  String? get _recommendedId {
    final ram = _ramGb;
    if (ram == null) return null;
    String? best;
    for (final m in localModelCatalog) {
      if (!m.sees && m.minRamGb <= ram + 0.5) best = m.id;
    }
    return best ?? localModelCatalog.first.id;
  }

  static String _gb(int bytes) => tr('{p} ГБ', {'p': (bytes / 1e9).toStringAsFixed(bytes < 1e9 ? 2 : 1)});

  Future<void> _download(LocalModelInfo m) async {
    final free = _freeBytes;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Скачать {name}?', {'name': m.name})),
        content: Text(
          tr('Размер {p} с huggingface.co. Лучше по Wi-Fi — мобильный трафик может стоить денег.{p2}{p3}\n\nКачается в фоне — приложение можно свернуть. Если загрузка прервётся, она продолжится с того же места.', {'p': _gb(m.totalBytes), 'p2': free != null && free < m.totalBytes * 1.1 ? tr('\n\nСвободного места мало: {p}.', {'p': _gb(free)}) : '', 'p3': _ramGb != null && _ramGb! + 0.5 < m.minRamGb ? tr('\n\nНужно от {minRamGb} ГБ ОЗУ, у устройства {p} — может работать медленно или закрываться.', {'minRamGb': m.minRamGb, 'p': _ramGb!.toStringAsFixed(1)}) : ''}),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(tr('Отмена'))),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(tr('Скачать'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _startDownload(m);
  }

  Future<void> _startDownload(LocalModelInfo m) async {
    if (!mounted) return;
    final note = _Downloads.progress[m.id] = ValueNotifier(0);
    setState(() {});
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Системный фоновый загрузчик: качает и при закрытом приложении,
      // с уведомлением; обрыв сети — продолжит сам. У модели «со зрением»
      // два файла — сама модель и проектор; прогресс общий по байтам.
      final files = [m, if (m.projector != null) m.projector!];
      for (final (i, f) in files.indexed) {
        final path = p.join(await modelsDir(), f.fileName);
        if (fileLength(path) != f.sizeBytes) {
          _Downloads.stage[m.id] =
              files.length == 1 ? '' : tr('Файл {p} из {length} ({p2}): ', {'p': i + 1, 'length': files.length, 'p2': f == m ? tr('модель') : tr('зрение')});
          note.value = 0;
          await downloadModel(
            id: f.id,
            url: f.url,
            fileName: f.fileName,
            displayName: f == m ? m.name : tr('{name} (зрение)', {'name': m.name}),
            // Не назад: после системной паузы загрузчик иногда присылает
            // чуть меньший процент, и полоса дёргалась 85→72→80.
            onProgress: (v) {
              if (v > note.value) note.value = v;
            },
          );
          note.value = -1; // проверка целостности
          if (await sha256OfFile(path) != f.sha256) {
            await deleteFile(path);
            throw Exception(tr('файл повреждён при загрузке, скачайте ещё раз'));
          }
        }
      }
      if (s.localModelId.isEmpty) s.localModelId = m.id;
      messenger.showSnackBar(SnackBar(content: Text(tr('{name} установлена', {'name': m.name}))));
    } on DownloadCancelled {
      messenger.showSnackBar(SnackBar(content: Text(tr('Загрузка приостановлена'))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('Не удалось скачать: {e}', {'e': e}))));
    } finally {
      _Downloads.progress.remove(m.id);
      _Downloads.stage.remove(m.id);
      await _refresh();
    }
  }

  void _resume(LocalModelInfo m) => _startDownload(m);

  Future<void> _delete(LocalModelInfo m) async {
    await LocalAi.instance.unload();
    for (final f in [m, if (m.projector != null) m.projector!]) {
      await deleteFile(p.join(await modelsDir(), f.fileName));
    }
    if (s.localModelId == m.id) s.localModelId = '';
    await _refresh();
  }

  Future<void> _runProbe(LocalModelInfo m) async {
    setState(() {
      _probing = true;
      _probe = null;
    });
    try {
      final r = await LocalAi.instance.probe(m);
      _probe = tr('{text}\n\n({p} с)', {'text': r.text, 'p': (r.took.inMilliseconds / 1000).toStringAsFixed(1)});
    } catch (e) {
      _probe = tr('Ошибка: {e}', {'e': e});
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!localAiSupported) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('Локальная модель'))),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(tr('В браузере локальная модель пока не работает — только в приложении для Android и Windows.')),
        ),
      );
    }
    final memory = LocalAiMemory(s.db);
    final recommended = _recommendedId;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Локальная модель'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            tr('ИИ прямо на устройстве, без интернета и ключей. Слабее облачного: лучше всего подходит для служебных задач.'),
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'off', label: Text(tr('Выкл'))),
              ButtonSegment(value: 'tasks', label: Text(tr('Служебные'))),
              ButtonSegment(value: 'all', label: Text(tr('Всё'))),
            ],
            selected: {s.localMode},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => s.localMode = v.first),
          ),
          const SizedBox(height: 8),
          Text(
            switch (s.localMode) {
              'tasks' => tr('Заметки, цвета, описания таблиц, отбор записей — локально. Не справилась — отвечает облако. Чат ассистента — в облаке.'),
              'all' => tr('Всё, включая чат ассистента, — локально (работает без интернета). Облако — только если локальная не ответила.'),
              _ => tr('Только облачный ИИ, как раньше.'),
            },
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Text(
            tr('Память устройства: {p}{p2}', {'p': _ramGb == null ? tr('неизвестно') : tr('{p} ГБ', {'p': _ramGb!.toStringAsFixed(1)}), 'p2': _freeBytes == null ? '' : tr(' · свободно на диске {p}', {'p': _gb(_freeBytes!)})}),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (final m in localModelCatalog) _modelTile(m, recommended),
          if (_probing) const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
          if (_probe != null)
            Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(_probe!))),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.memory_outlined),
            title: Text(tr('Память локальной модели')),
            subtitle: Text(
              tr('{count} записей, {p} из {p2} тыс. символов. Готовые ответы и удачные примеры облака — старое вытесняется само.', {'count': memory.count, 'p': (memory.usedChars / 1000).toStringAsFixed(0), 'p2': (memory.maxChars / 1000).toStringAsFixed(0)}),
            ),
            trailing: TextButton(
              onPressed: () => setState(memory.clear),
              child: Text(tr('Очистить')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modelTile(LocalModelInfo m, String? recommended) {
    final theme = Theme.of(context);
    final installed = _installed[m.id] == true;
    final selected = s.localModelId == m.id;
    final tooHeavy = _ramGb != null && _ramGb! + 0.5 < m.minRamGb;
    final progress = _Downloads.progress[m.id];
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
                    tooltip: tr('Использовать эту модель'),
                    icon: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                    onPressed: () => setState(() => s.localModelId = m.id),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${m.name} · ${tr(m.tier)}', style: theme.textTheme.titleSmall),
                      Text(tr('{p} · от {minRamGb} ГБ ОЗУ', {'p': _gb(m.totalBytes), 'minRamGb': m.minRamGb}), style: theme.textTheme.bodySmall),
                      if (m.sees)
                        Text(tr('Видит фото — ищет пробоины на «Фото мишени»'),
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
                      Text(tr(m.note), style: theme.textTheme.bodySmall),
                      if (m.id == recommended)
                        Text(tr('Рекомендуется для этого устройства'),
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
                      if (tooHeavy)
                        Text(tr('Может не потянуть: мало памяти'),
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                    ],
                  ),
                ),
                if (progress == null && !installed)
                  IconButton(
                    tooltip: tr('Скачать'),
                    icon: const Icon(Icons.download_outlined),
                    onPressed: () => _download(m),
                  ),
                if (progress != null)
                  IconButton(
                    tooltip: tr('Приостановить'),
                    icon: const Icon(Icons.pause_outlined),
                    onPressed: () async {
                      await pauseModelDownload(m.id);
                      if (m.projector != null) await pauseModelDownload(m.projector!.id);
                    },
                  ),
                if (installed) ...[
                  IconButton(
                    tooltip: tr('Проверить'),
                    icon: const Icon(Icons.play_arrow_outlined),
                    onPressed: _probing ? null : () => _runProbe(m),
                  ),
                  IconButton(
                    tooltip: tr('Удалить'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(m),
                  ),
                ],
              ],
            ),
            if (progress != null)
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (_, v, __) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(value: v < 0 ? null : v),
                    Text(
                        '${_Downloads.stage[m.id] ?? ''}'
                        '${v < 0 ? 'проверка файла…' : '${(v * 100).toStringAsFixed(0)}%'}',
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            if (installed && selected && s.localMode == 'off')
              Text(tr('Выбрана, но режим «Выкл» — включите «Служебные» или «Всё».'),
                  style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
