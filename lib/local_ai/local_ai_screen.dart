import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/ai_settings.dart';
import 'local_ai.dart';
import 'local_ai_catalog.dart';
import 'local_ai_memory.dart';
import 'local_ai_platform.dart';

/// Идущие загрузки живут дольше экрана: закрыли настройки — качается дальше.
class _Downloads {
  static final Map<String, ValueNotifier<double>> progress = {};
}

/// Настройки локальной модели (режим разработчика): режим работы, выбор и
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
      if (_installed[m.id] != true && !_Downloads.progress.containsKey(m.id) && await modelDownloadActive(m.id)) {
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
      if (m.minRamGb <= ram + 0.5) best = m.id;
    }
    return best ?? localModelCatalog.first.id;
  }

  static String _gb(int bytes) => '${(bytes / 1e9).toStringAsFixed(bytes < 1e9 ? 2 : 1)} ГБ';

  Future<void> _download(LocalModelInfo m) async {
    final free = _freeBytes;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Скачать ${m.name}?'),
        content: Text(
          'Размер ${_gb(m.sizeBytes)} с huggingface.co. Лучше по Wi-Fi — мобильный трафик может стоить денег.'
          '${free != null && free < m.sizeBytes * 1.1 ? '\n\nСвободного места мало: ${_gb(free)}.' : ''}'
          '${_ramGb != null && _ramGb! + 0.5 < m.minRamGb ? '\n\nНужно от ${m.minRamGb} ГБ ОЗУ, у устройства ${_ramGb!.toStringAsFixed(1)} — может работать медленно или закрываться.' : ''}'
          '\n\nКачается в фоне с уведомлением — приложение можно закрыть. Пауза продолжится с того же места.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Скачать')),
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
      final path = p.join(await modelsDir(), m.fileName);
      // Системный фоновый загрузчик: качает и при закрытом приложении,
      // с уведомлением; обрыв сети — продолжит сам.
      await downloadModel(
        id: m.id,
        url: m.url,
        fileName: m.fileName,
        displayName: m.name,
        onProgress: (v) => note.value = v,
      );
      note.value = -1; // проверка целостности
      if (await sha256OfFile(path) != m.sha256) {
        await deleteFile(path);
        throw Exception('файл повреждён при загрузке, скачайте ещё раз');
      }
      if (s.localModelId.isEmpty) s.localModelId = m.id;
      messenger.showSnackBar(SnackBar(content: Text('${m.name} установлена')));
    } on DownloadCancelled {
      messenger.showSnackBar(const SnackBar(content: Text('Загрузка приостановлена')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Не удалось скачать: $e')));
    } finally {
      _Downloads.progress.remove(m.id);
      await _refresh();
    }
  }

  void _resume(LocalModelInfo m) => _startDownload(m);

  Future<void> _delete(LocalModelInfo m) async {
    await LocalAi.instance.unload();
    await deleteFile(p.join(await modelsDir(), m.fileName));
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
      _probe = '${r.text}\n\n(${(r.took.inMilliseconds / 1000).toStringAsFixed(1)} с)';
    } catch (e) {
      _probe = 'Ошибка: $e';
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!localAiSupported) {
      return Scaffold(
        appBar: AppBar(title: const Text('Локальная модель')),
        body: const Padding(
          padding: EdgeInsets.all(24),
          child: Text('В браузере локальная модель пока не работает — только в приложении для Android и Windows.'),
        ),
      );
    }
    final memory = LocalAiMemory(s.db);
    final recommended = _recommendedId;
    return Scaffold(
      appBar: AppBar(title: const Text('Локальная модель')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            'ИИ прямо на устройстве, без интернета и ключей. Слабее облачного: '
            'лучше всего подходит для служебных задач.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'off', label: Text('Выкл')),
              ButtonSegment(value: 'tasks', label: Text('Служебные')),
              ButtonSegment(value: 'all', label: Text('Всё')),
            ],
            selected: {s.localMode},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => s.localMode = v.first),
          ),
          const SizedBox(height: 8),
          Text(
            switch (s.localMode) {
              'tasks' => 'Заметки, цвета, описания таблиц, отбор записей — локально. '
                  'Не справилась — отвечает облако. Чат ассистента — в облаке.',
              'all' => 'Всё, включая чат ассистента, — локально (работает без интернета). '
                  'Облако — только если локальная не ответила.',
              _ => 'Только облачный ИИ, как раньше.',
            },
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Text(
            'Память устройства: ${_ramGb == null ? 'неизвестно' : '${_ramGb!.toStringAsFixed(1)} ГБ'}'
            '${_freeBytes == null ? '' : ' · свободно на диске ${_gb(_freeBytes!)}'}',
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
            title: const Text('Память локальной модели'),
            subtitle: Text(
              '${memory.count} записей, ${(memory.usedChars / 1000).toStringAsFixed(0)} из '
              '${(memory.maxChars / 1000).toStringAsFixed(0)} тыс. символов. Готовые ответы и удачные '
              'примеры облака — старое вытесняется само.',
            ),
            trailing: TextButton(
              onPressed: () => setState(memory.clear),
              child: const Text('Очистить'),
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
                    tooltip: 'Использовать эту модель',
                    icon: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                    onPressed: () => setState(() => s.localModelId = m.id),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${m.name} · ${m.tier}', style: theme.textTheme.titleSmall),
                      Text('${_gb(m.sizeBytes)} · от ${m.minRamGb} ГБ ОЗУ', style: theme.textTheme.bodySmall),
                      Text(m.note, style: theme.textTheme.bodySmall),
                      if (m.id == recommended)
                        Text('Рекомендуется для этого устройства',
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
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
                    onPressed: () => _download(m),
                  ),
                if (progress != null)
                  IconButton(
                    tooltip: 'Приостановить',
                    icon: const Icon(Icons.pause_outlined),
                    onPressed: () => pauseModelDownload(m.id),
                  ),
                if (installed) ...[
                  IconButton(
                    tooltip: 'Проверить',
                    icon: const Icon(Icons.play_arrow_outlined),
                    onPressed: _probing ? null : () => _runProbe(m),
                  ),
                  IconButton(
                    tooltip: 'Удалить',
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
                    Text(v < 0 ? 'Проверка файла…' : '${(v * 100).toStringAsFixed(0)}%',
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            if (installed && selected && s.localMode == 'off')
              Text('Выбрана, но режим «Выкл» — включите «Служебные» или «Всё».',
                  style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
