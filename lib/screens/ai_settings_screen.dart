import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ai_service.dart';
import '../services/knowledge_service.dart';
import '../services/ai_settings.dart';
import '../state/app_data_store.dart';
import '../widgets/section_header.dart';

/// Настройки ассистента: ключ, цепочка моделей, справочные материалы.
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  late final AiSettings _settings;
  late final TextEditingController _key;
  late final TextEditingController _models;
  late final TextEditingController _booksUrl;
  late final TextEditingController _booksToken;
  late final TextEditingController _customInstructions;

  List<String>? _available;
  bool _loading = false;
  String? _message;

  /// Результаты проверки цепочки: модель → что ответил сервер.
  final Map<String, String> _probe = {};
  bool _probing = false;

  /// Состояние таблиц базы знаний: таблица → «128 записей» / «пусто».
  Map<String, String>? _books;
  bool _checkingBooks = false;

  /// Пользователь ввёл собственный ключ, а не пользуется вшитым.
  late bool _ownKey;

  /// Таблицы справочника — редактируемый список.
  late List<KnowledgeTableConfig> _tables;

  @override
  void initState() {
    super.initState();
    _settings = AiSettings(context.read<AppDataStore>().db);
    _ownKey = _settings.hasOwnKey;
    _key = TextEditingController(text: _ownKey ? _settings.apiKey : '');
    _tables = [..._settings.tables];
    // Со своим ключом поле цепочки стартует ПУСТЫМ, если пользователь
    // ещё ничего не вводил — не подставляем модели, подобранные под
    // встроенный бесплатный ключ, это разные наборы задач/ограничений.
    _models = TextEditingController(text: _ownKey ? _settings.rawModels : _settings.models.join('\n'));
    _booksUrl = TextEditingController(text: _settings.booksUrl);
    _booksToken = TextEditingController(text: _settings.booksToken);
    _customInstructions = TextEditingController(text: _settings.customInstructions);
  }

  @override
  void dispose() {
    _key.dispose();
    _models.dispose();
    _booksUrl.dispose();
    _booksToken.dispose();
    _customInstructions.dispose();
    super.dispose();
  }

  /// Со встроенным ключом предел заметно уже — экран использует ЭТОТ
  /// геттер (не `_settings.customInstructionsLimit`), чтобы предел в UI
  /// менялся сразу при переключении сегмента, не дожидаясь "Сохранить".
  int get _customInstructionsLimit => _ownKey
      ? AiSettings.customInstructionsLimitOwnKey
      : AiSettings.customInstructionsLimitBuiltIn;

  void _save() {
    _settings.apiKey = _ownKey ? _key.text : '';
    _settings.tables = _tables;
    _settings.models = _models.text.split('\n');
    _settings.booksUrl = _booksUrl.text;
    _settings.booksToken = _booksToken.text;
    final rawInstructions = _customInstructions.text;
    _settings.customInstructions = rawInstructions.length > _customInstructionsLimit
        ? rawInstructions.substring(0, _customInstructionsLimit)
        : rawInstructions;
    // "Сохранить" — это закрыть экран настроек, а не остаться на нём:
    // настройки — не рабочий экран, к которому возвращаются, а разовое
    // действие, после которого логично вернуться туда, откуда пришёл.
    Navigator.of(context).pop();
  }

  Future<void> _loadModels() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final list = await AiService(_settings).fetchFreeModels();
      setState(() => _available = list);
    } catch (e) {
      setState(() => _message = '$e');
    } finally {
      setState(() => _loading = false);
    }
  }

  /// Прогоняет цепочку по очереди, а не разом: параллельные запросы с
  /// одного ключа провайдеры охотно встречают ответом 429, и проверка
  /// начинает врать про живые модели.
  Future<void> _probeModels() async {
    // Проверяем то, что сейчас в поле, даже если пользователь ещё не
    // нажал «Сохранить» — иначе проверка идёт не по тому списку,
    // который человек видит перед собой.
    final list = _models.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (list.isEmpty) return;

    setState(() {
      _probing = true;
      _probe.clear();
      _message = null;
    });

    final service = AiService(_settings);
    for (final model in list) {
      final result = await service.probeModel(model);
      if (!mounted) return;
      setState(() => _probe[model] = result);
    }
    if (!mounted) return;
    // Рабочие модели остаются в порядке, который написал пользователь,
    // неответившие уходят в конец списка (решение пользователя, пункт 3
    // списка правок) — так цепочка сама чинится по итогам проверки, а не
    // только показывает, что где-то что-то не отвечает.
    final working = [for (final m in list) if (_probeOk(_probe[m] ?? '')) m];
    final failing = [for (final m in list) if (!_probeOk(_probe[m] ?? '')) m];
    setState(() {
      _models.text = [...working, ...failing].join('\n');
      _probing = false;
    });
  }

  /// Встроенный ключ: одна кнопка вместо ручного набора цепочки. Тянет
  /// список бесплатных моделей у OpenRouter и просит уже настроенную
  /// (пусть даже дефолтную) цепочку отсортировать его по пригодности для
  /// задачи ассистента — решение пользователя, пункт 3 списка правок.
  Future<void> _autoConfigureModels() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final service = AiService(_settings);
      final free = await service.fetchFreeModels();
      if (free.isEmpty) throw const AiException('Бесплатных моделей сейчас нет');
      final reply = await service.ask(
        systemPrompt: 'Ты помогаешь настроить цепочку ИИ-моделей для ассистента по '
            'спортивной стрельбе. Нужны модели, которые точно считают арифметику '
            '(например, среднюю точку попадания и кучность по координатам выстрелов) '
            'и не рассуждают вслух подолгу — ответ должен быть коротким и по делу, а не '
            'дорогим и медленным.',
        contextBlock: 'Доступные бесплатные модели OpenRouter прямо сейчас, по одной в строке:\n'
            '${free.join('\n')}',
        history: const [
          (
            role: 'user',
            text: 'Распредели эти модели по приоритету для описанной задачи и дай мне '
                'список без лишнего текста — по одной модели в строке, в этом же формате '
                'id, что и во входном списке, от самой подходящей к наименее подходящей.',
          ),
        ],
      );
      final ranked = reply.text
          .split('\n')
          .map((l) => l.trim())
          .where(free.contains)
          .toList();
      if (ranked.isEmpty) throw const AiException('Не удалось разобрать ответ модели — попробуйте ещё раз');
      _settings.models = ranked;
      setState(() {
        _models.text = ranked.join('\n');
        _message = 'Подобрано моделей: ${ranked.length}';
      });
    } catch (e) {
      setState(() => _message = '$e');
    } finally {
      setState(() => _loading = false);
    }
  }

  /// Добавляет таблицу в список поиска — имя обязательно, название и
  /// описание нет (пункт 12 списка правок: чтобы ИИ понимал, что в
  /// таблице лежит, а не только откуда она).
  Future<void> _addTable() async {
    final nameCtrl = TextEditingController();
    final labelCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final config = await showDialog<KnowledgeTableConfig>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новая таблица'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Напишите имя таблицы'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: labelCtrl,
              decoration: const InputDecoration(labelText: 'Название (необязательно)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: descCtrl,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Краткое описание (необязательно)',
                hintText: 'Что в этой таблице — чтобы ИИ понимал',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              Navigator.of(ctx).pop(KnowledgeTableConfig(
                name: name,
                label: labelCtrl.text.trim().isEmpty ? null : labelCtrl.text.trim(),
                description: descCtrl.text.trim(),
              ));
            },
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (config == null) return;
    if (!mounted) return;
    setState(() {
      if (!_tables.any((t) => t.name == config.name)) _tables.add(config);
    });
  }

  /// Считает записи в таблицах справочника — по введённым в полях
  /// адресу и токену, а не по сохранённым: проверять надо то, что
  /// человек видит перед собой.
  Future<void> _checkBooks() async {
    setState(() {
      _checkingBooks = true;
      _books = null;
    });
    _settings.booksUrl = _booksUrl.text;
    _settings.booksToken = _booksToken.text;
    // Таблицы тоже нужно сохранить ПЕРЕД проверкой — иначе таблица,
    // только что добавленная кнопкой "Добавить" (живёт пока в _tables,
    // а не на диске), в проверке не участвует: tableStatus читает
    // settings.tables, а это сохранённое значение (баг, найденный
    // пользователем на таблице "notes").
    _settings.tables = _tables;
    final status = await KnowledgeService(_settings).tableStatus();
    if (!mounted) return;
    setState(() {
      _books = status;
      _checkingBooks = false;
    });
  }

  /// Ответ проверки считаем успешным по нашему же формату строки —
  /// probeModel возвращает либо «ответила за …», либо текст ошибки.
  static bool _probeOk(String result) => result.startsWith('ответила');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ассистент'),
        actions: [TextButton(onPressed: _save, child: const Text('СОХРАНИТЬ'))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const SectionHeader(
            title: 'Доступ',
            subtitle: 'Ключ OpenRouter. Хранится только на этом устройстве.',
          ),
          const SizedBox(height: 12),
          // Переключатель вместо прежнего предупреждения: поле ключа
          // показывается, только когда пользователь выбрал свой ключ.
          // Постоянная плашка «ключ можно достать из сборки» висела над
          // экраном всегда и ничего не меняла.
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Ключ из сборки')),
              ButtonSegment(value: true, label: Text('Свой ключ')),
            ],
            selected: {_ownKey},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() {
              _ownKey = v.first;
              if (!_ownKey) {
                _key.text = '';
                // Возвращаемся к эффективной цепочке встроенного ключа
                // (например, уже подобранной кнопкой "Подобрать модели").
                _models.text = _settings.models.join('\n');
              } else if (_models.text == _settings.models.join('\n')) {
                // Поле ещё показывает набор встроенного ключа — со своим
                // ключом это чужой список, начинаем с чистого листа.
                _models.text = _settings.rawModels;
              }
            }),
          ),
          if (_ownKey) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              decoration: const InputDecoration(
                labelText: 'Ключ OpenRouter',
                hintText: 'sk-or-v1-…',
              ),
              obscureText: true,
            ),
          ] else if (AiSettings.testApiKey.isEmpty) ...[
            // Ключ подставляется на сборке (--dart-define). Если его
            // туда не передали, «ключ из сборки» — это пустая строка, и
            // ассистент будет молча получать 401. Сказать об этом здесь
            // дешевле, чем разбираться по ошибке в чате.
            const SizedBox(height: 12),
            Text(
              'В этой сборке ключа нет — ассистент не ответит. '
              'Переключитесь на «Свой ключ» и вставьте свой.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
            ),
          ],
          const SizedBox(height: 24),
          const SectionHeader(
            title: 'Инструкция ассистенту',
            subtitle: 'Что ещё должен знать ИИ',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _customInstructions,
            minLines: 2,
            maxLines: 6,
            maxLength: _customInstructionsLimit,
            decoration: const InputDecoration(labelText: 'Что ещё должен знать ИИ'),
          ),
          const SizedBox(height: 24),
          // Окно выбора цепочки моделей нужно, только когда пользователь
          // сам подставляет ключ — со встроенным ключом ручной выбор
          // модели заменяет одна кнопка ниже (решение пользователя,
          // пункт 2 списка правок).
          if (_ownKey) ...[
            SectionHeader(
              title: 'Модели',
              subtitle: 'По одной в строке, сверху вниз. Не ответила первая — берётся следующая.',
              trailing: _loading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : TextButton(onPressed: _loadModels, child: const Text('Обновить')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _models,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(labelText: 'Цепочка моделей'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _probing ? null : _probeModels,
                  icon: _probing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_circle_outline, size: 18),
                  label: const Text('Проверить'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Не ответившие модели уйдут в конец списка, рабочие останутся в вашем порядке',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            if (_probe.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (final e in _probe.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        _probeOk(e.value) ? Icons.check_circle : Icons.cancel_outlined,
                        size: 16,
                        color: _probeOk(e.value) ? Colors.green.shade600 : cs.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(
                              text: '${e.key}\n',
                              style: theme.textTheme.labelSmall,
                            ),
                            TextSpan(
                              text: e.value,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ]),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            if (_available != null) ...[
              const SizedBox(height: 12),
              Text(
                'Бесплатные модели сейчас (${_available!.length}) — нажмите, чтобы добавить:',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final m in _available!)
                    ActionChip(
                      label: Text(m, style: theme.textTheme.labelSmall),
                      onPressed: () => setState(() {
                        final lines = _models.text.split('\n').where((e) => e.trim().isNotEmpty).toList();
                        if (!lines.contains(m)) lines.add(m);
                        _models.text = lines.join('\n');
                      }),
                    ),
                ],
              ),
            ],
          ] else ...[
            const SectionHeader(title: 'Модели'),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _loading ? null : _autoConfigureModels,
                  icon: _loading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_fix_high, size: 18),
                  label: const Text('Подобрать модели'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Переподключить доступные модели',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Сейчас в цепочке: ${_settings.models.length} модел${_settings.models.length == 1 ? 'ь' : _settings.models.length < 5 ? 'и' : 'ей'}',
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 24),
          const SectionHeader(title: 'Справочные материалы'),
          const SizedBox(height: 12),
          TextField(
            controller: _booksUrl,
            decoration: const InputDecoration(labelText: 'URL таблицы'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _booksToken,
            decoration: const InputDecoration(labelText: 'Токен (если нужен)'),
            obscureText: true,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _checkingBooks ? null : _checkBooks,
                icon: _checkingBooks
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.storage_outlined, size: 18),
                label: const Text('Проверить базу'),
              ),
              const SizedBox(width: 10),
              if (_books != null)
                Expanded(
                  child: Text(
                    _books!.entries.map((e) => '${e.key}: ${e.value}').join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text('Подключённые таблицы', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in _tables)
                InputChip(
                  label: Text(t.label),
                  tooltip: t.description.isEmpty ? null : t.description,
                  onDeleted: () => setState(() => _tables.remove(t)),
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: const Text('Добавить'),
                onPressed: _addTable,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Напишите имя таблицы',
            style: theme.textTheme.bodySmall,
          ),
          if (_message != null) ...[
            const SizedBox(height: 20),
            Text(_message!, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
