import '../local_ai/local_ai_platform.dart';
import '../local_ai/local_ai_screen.dart';
import '../widgets/glass_pill.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../logic/ai_context.dart';
import '../services/ai_service.dart';
import '../services/knowledge_service.dart';
import '../services/ai_settings.dart';
import '../services/local_db_service.dart';
import '../services/supabase_auth_service.dart';
import '../state/app_data_store.dart';
import '../widgets/section_header.dart';
import '../i18n/i18n.dart';

/// Настройки ассистента: ключ, цепочка моделей, справочные материалы.
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  late final AiSettings _settings;
  late final TextEditingController _key;
  late final TextEditingController _apiBaseUrl;
  late final TextEditingController _models;
  late final TextEditingController _customInstructions;
  late final TextEditingController _baseInstructions;
  late final TextEditingController _geminiKey;
  bool _editingBase = false;
  late final SupabaseAuthService _personalAuth;
  late final LocalDbService _db;

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

  /// Единый трёхпозиционный выбор источника ИИ (решение пользователя,
  /// пункт 11 списка правок) — раньше «Локальный» был отдельной плиткой
  /// сбоку, теперь это такой же равноправный третий вариант, как
  /// встроенный/свой ключ, и выбор одного выключает остальные.
  late String _mode; // 'builtin' | 'ownKey' | 'local'

  @override
  void initState() {
    super.initState();
    _db = context.read<AppDataStore>().db;
    _settings = AiSettings(_db);
    _personalAuth = SupabaseAuthService(_db);
    _ownKey = _settings.hasOwnKey;
    _mode = _settings.localMode != 'off'
        ? 'local'
        : (_ownKey ? 'ownKey' : 'builtin');
    _key = TextEditingController(text: _ownKey ? _settings.apiKey : '');
    // Адрес по умолчанию не показываем — пустое поле = встроенный сервис.
    _apiBaseUrl = TextEditingController(
        text: _settings.apiBaseUrl == AiSettings.defaultApiBaseUrl
            ? ''
            : _settings.apiBaseUrl);
    // Со своим ключом поле цепочки стартует ПУСТЫМ, если пользователь
    // ещё ничего не вводил — не подставляем модели, подобранные под
    // встроенный бесплатный ключ, это разные наборы задач/ограничений.
    _models = TextEditingController(
        text: _ownKey ? _settings.rawModels : _settings.models.join('\n'));
    _customInstructions =
        TextEditingController(text: _settings.customInstructions);
    _geminiKey = TextEditingController(text: _settings.geminiKey);
    _baseInstructions = TextEditingController(
        text: _settings.baseInstructionsOverride.isEmpty
            ? AiContext.defaultBasePrompt
            : _settings.baseInstructionsOverride);
  }

  @override
  void dispose() {
    _key.dispose();
    _apiBaseUrl.dispose();
    _models.dispose();
    _customInstructions.dispose();
    _baseInstructions.dispose();
    _geminiKey.dispose();
    super.dispose();
  }

  /// Со встроенным ключом предел заметно уже — экран использует ЭТОТ
  /// геттер (не `_settings.customInstructionsLimit`), чтобы предел в UI
  /// менялся сразу при переключении сегмента, не дожидаясь "Сохранить".
  int get _customInstructionsLimit => _mode == 'ownKey'
      ? AiSettings.customInstructionsLimitOwnKey
      : AiSettings.customInstructionsLimitBuiltIn;

  void _save() {
    if (_mode != 'local' && _settings.localMode != 'off')
      _settings.localMode = 'off';
    _settings.apiKey = _ownKey ? _key.text : '';
    _settings.apiBaseUrl = _apiBaseUrl.text.isEmpty
        ? AiSettings.defaultApiBaseUrl
        : _apiBaseUrl.text;
    _settings.models = _models.text.split('\n');
    final rawInstructions = _customInstructions.text;
    _settings.customInstructions =
        rawInstructions.length > _customInstructionsLimit
            ? rawInstructions.substring(0, _customInstructionsLimit)
            : rawInstructions;
    _settings.geminiKey = _geminiKey.text;
    // Не храним копию дефолтного текста как «переопределение» — override
    // пустой, если пользователь его не менял (или вручную вернул как было).
    _settings.baseInstructionsOverride =
        _baseInstructions.text.trim() == AiContext.defaultBasePrompt.trim()
            ? ''
            : _baseInstructions.text;
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
      // Пауза между запросами (пункт 7 списка правок): без неё подряд
      // идущие запросы с одного ключа провайдеры иногда встречают сбоем
      // — не 429 явным текстом, а обрывком ответа, который выглядит как
      // "модель не ответила", хотя дело не в самой модели.
      if (model != list.last)
        await Future.delayed(const Duration(milliseconds: 400));
    }
    if (!mounted) return;
    // Рабочие модели остаются в порядке, который написал пользователь,
    // неответившие уходят в конец списка (решение пользователя, пункт 3
    // списка правок) — так цепочка сама чинится по итогам проверки, а не
    // только показывает, что где-то что-то не отвечает.
    final working = [
      for (final m in list)
        if (_probeOk(_probe[m] ?? '')) m
    ];
    final failing = [
      for (final m in list)
        if (!_probeOk(_probe[m] ?? '')) m
    ];
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
      if (free.isEmpty) throw AiException(tr('Бесплатных моделей сейчас нет'));
      final preferSpeed = _settings.modelPriority == 'speed';
      final reply = await service.ask(
        systemPrompt: preferSpeed
            ? 'Ты помогаешь настроить цепочку ИИ-моделей для ассистента по спортивной '
                'стрельбе. Приоритет — скорость и краткость ответа: модель не должна '
                'подолгу рассуждать вслух, даже если это немного снижает точность '
                'арифметики.'
            : 'Ты помогаешь настроить цепочку ИИ-моделей для ассистента по '
                'спортивной стрельбе. Нужны модели, которые точно считают арифметику '
                '(например, среднюю точку попадания и кучность по координатам выстрелов) '
                'и не рассуждают вслух подолгу — ответ должен быть коротким и по делу, а не '
                'дорогим и медленным.',
        contextBlock:
            'Доступные бесплатные модели OpenRouter прямо сейчас, по одной в строке:\n'
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
      if (ranked.isEmpty)
        throw AiException(
            tr('Не удалось разобрать ответ моделей — попробуйте ещё раз'));
      _settings.models = ranked;
      setState(() {
        _models.text = ranked.join('\n');
        _message = tr('Подобрано моделей: {length}', {'length': ranked.length});
      });
    } catch (e) {
      setState(() => _message = '$e');
    } finally {
      setState(() => _loading = false);
    }
  }

  /// Считает записи в подключённых таблицах — общей базе (вшита) и
  /// личных, которые пользователь выбрал в настройках учётной записи.
  Future<void> _checkBooks() async {
    setState(() {
      _checkingBooks = true;
      _books = null;
    });
    final status = await KnowledgeService(
      _settings,
      db: _db,
      aiService: AiService(_settings),
      personalAuth: _personalAuth,
    ).tableStatus();
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

    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Ассистент'),
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        actions: [
          GlassCircleButton(
              icon: const BoldIcon(Icons.check),
              tooltip: tr('Сохранить'),
              onTap: _save),
        ],
      ),
      body: ListView(
        padding:
            EdgeInsets.fromLTRB(16, topInset + GlassHeader.height + 8, 16, 32),
        children: [
          SectionHeader(
            title: tr('Доступ'),
            subtitle: switch (_mode) {
              'local' => tr(
                  'Использует производительные мощности этого устройства (долгие ответы и нагрев устройства)'),
              'ownKey' => tr(
                  'Плата взимается поставщиком услуг (возможности, скорость, расход зависят от выбранной LLM модели)'),
              _ => tr('Бесплатный облачный сервис'),
            },
          ),
          const SizedBox(height: 12),
          // Один трёхпозиционный выбор вместо отдельной плитки «Локальная
          // модель» сбоку — Локальный теперь равноправная альтернатива
          // облаку, а не довесок (решение пользователя, пункт 11).
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'builtin', label: Text(tr('Бесплатный'))),
              ButtonSegment(value: 'ownKey', label: Text(tr('Свой ключ'))),
              if (localAiSupported)
                ButtonSegment(value: 'local', label: Text(tr('На устройстве'))),
            ],
            selected: {_mode},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() {
              _mode = v.first;
              _ownKey = _mode == 'ownKey';
              if (_mode == 'local' && _settings.localMode == 'off')
                _settings.localMode = 'tasks';
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
          if (_mode == 'local') ...[
            const SizedBox(height: 12),
            LocalAiPanel(settings: _settings),
          ] else ...[
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'quality', label: Text(tr('Качество'))),
                ButtonSegment(value: 'speed', label: Text(tr('Скорость'))),
              ],
              selected: {_settings.modelPriority},
              showSelectedIcon: false,
              onSelectionChanged: (v) =>
                  setState(() => _settings.modelPriority = v.first),
            ),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Режим мышления')),
            subtitle: Text(tr(
                'Несколько ИИ по очереди: план → решение по шагам → ответ. Точнее на сложных вопросах, но медленнее и тратит больше запросов. По умолчанию — быстрый режим.')),
            value: _settings.thinkingMode,
            onChanged: (v) => setState(() => _settings.thinkingMode = v),
          ),
          if (_ownKey) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              decoration: const InputDecoration(labelText: 'API Key'),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiBaseUrl,
              decoration: InputDecoration(
                labelText: 'URL',
                helperText:
                    tr('Адрес API вашего сервиса (совместимого с OpenAI)'),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
          ] else if (_mode == 'builtin' && AiSettings.testApiKey.isEmpty) ...[
            // Ключ подставляется на сборке (--dart-define). Если его
            // туда не передали, «ключ из сборки» — это пустая строка, и
            // ассистент будет молча получать 401. Сказать об этом здесь
            // дешевле, чем разбираться по ошибке в чате.
            const SizedBox(height: 12),
            Text(
              tr('В этой сборке ключа нет — ассистент не ответит. Переключитесь на «Свой ключ» и вставьте свой.'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
            ),
          ],
          const SizedBox(height: 24),
          SectionHeader(
            title: tr('Поиск в интернете'),
            subtitle: tr(
                'Ответ из Google прямо в чате: вставьте бесплатный ключ Gemini (aistudio.google.com → Get API key)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _geminiKey,
            obscureText: true,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Gemini API Key'),
          ),
          const SizedBox(height: 24),
          SectionHeader(title: tr('Инструкция ассистенту')),
          const SizedBox(height: 12),
          TextField(
            controller: _customInstructions,
            minLines: 2,
            maxLines: 6,
            maxLength: _customInstructionsLimit,
            decoration:
                InputDecoration(labelText: tr('Что ещё должен знать ИИ')),
          ),
          const SizedBox(height: 12),
          // Встроенные правила ассистента — видны пользователю, а не
          // только зашиты в коде, и их можно переписать целиком (решение
          // пользователя, пункты 2/3/6 списка правок).
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(tr('Встроенные правила ассистента'),
                  style: theme.textTheme.bodyMedium),
              children: [
                if (_editingBase) ...[
                  Text(
                    tr('Осторожно: формат ```chart/```exercise/```note/```feedback должен остаться в тексте — иначе перестанут работать графики и предложения упражнений/заметок/отзыва.'),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _baseInstructions,
                    minLines: 6,
                    maxLines: 20,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => setState(() {
                          _baseInstructions.text = AiContext.defaultBasePrompt;
                        }),
                        child: Text(tr('Восстановить по умолчанию')),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(() => _editingBase = false),
                        child: Text(tr('Готово')),
                      ),
                    ],
                  ),
                ] else ...[
                  SelectableText(
                    _baseInstructions.text,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => setState(() => _editingBase = true),
                      child: Text(tr('Редактировать')),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Окно выбора цепочки моделей нужно, только когда пользователь
          // сам подставляет ключ — со встроенным ключом ручной выбор
          // модели заменяет одна кнопка ниже (решение пользователя,
          // пункт 2 списка правок).
          if (_ownKey) ...[
            SectionHeader(
              title: tr('Модели'),
              subtitle: tr('Список используемых ИИ моделей'),
              trailing: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : TextButton(
                      onPressed: _loadModels, child: Text(tr('Обновить'))),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _models,
              minLines: 3,
              maxLines: 8,
              decoration: InputDecoration(
                  labelText: tr('ИИ модели (по одной в строке)')),
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
                  label: Text(tr('Тест ИИ')),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr('Проверка ИИ моделей'),
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
                        _probeOk(e.value)
                            ? Icons.check_circle
                            : Icons.cancel_outlined,
                        size: 16,
                        color: _probeOk(e.value)
                            ? Colors.green.shade600
                            : cs.error,
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
                tr('Бесплатные модели сейчас ({p}) — нажмите, чтобы добавить:',
                    {'p': _available!.length}),
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
                        final lines = _models.text
                            .split('\n')
                            .where((e) => e.trim().isNotEmpty)
                            .toList();
                        if (!lines.contains(m)) lines.add(m);
                        _models.text = lines.join('\n');
                      }),
                    ),
                ],
              ),
            ],
          ] else ...[
            SectionHeader(title: tr('Модели')),
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
                  label: Text(tr('Подобрать модели')),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr('Переподключить доступные модели'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              tr('Сейчас в цепочке: {length} модел{p}', {
                'length': _settings.models.length,
                'p': _settings.models.length == 1
                    ? tr('ь')
                    : _settings.models.length < 5
                        ? tr('и')
                        : tr('ей')
              }),
              style: theme.textTheme.bodySmall,
            ),
          ],
          // Справочные материалы — для всех (решение пользователя).
          ...[
            const SizedBox(height: 24),
            SectionHeader(
              title: tr('Справочные материалы'),
              subtitle: tr(
                  'Книги и правила стрельбы встроены в приложение — подключать вручную не нужно. Свои таблицы добавляются в настройках учётной записи.'),
            ),
            const SizedBox(height: 12),
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
                  label: Text(tr('Проверить базу')),
                ),
                const SizedBox(width: 10),
                if (_books != null)
                  Expanded(
                    child: Text(
                      _books!.entries
                          .map((e) => '${e.key}: ${e.value}')
                          .join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ],
          if (_message != null) ...[
            const SizedBox(height: 20),
            Text(_message!, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
