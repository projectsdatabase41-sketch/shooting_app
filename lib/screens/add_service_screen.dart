import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../logic/service_connection_parser.dart';
import '../models/custom_service.dart';
import '../services/ai_service.dart';
import '../services/ai_settings.dart';
import '../services/custom_services_repository.dart';
import '../state/app_data_store.dart';
import '../widgets/service_icon_picker.dart';

/// Добавление/изменение плитки стороннего сервиса — три способа описать
/// подключение (решение пользователя): просто ссылка (+ необязательный
/// ключ API), cURL-команда или JSON. Все три в итоге дают один и тот же
/// набор полей (`ParsedConnection`) — вкладки только про удобство ввода.
///
/// `existing != null` — режим изменения (то же самое сохранение, только
/// не создаёт новую строку, а обновляет).
class AddServiceScreen extends StatefulWidget {
  final CustomServicesRepository repo;
  final CustomService? existing;
  const AddServiceScreen({super.key, required this.repo, this.existing});

  @override
  State<AddServiceScreen> createState() => _AddServiceScreenState();
}

class _AddServiceScreenState extends State<AddServiceScreen> with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _apiKey = TextEditingController();
  final _curl = TextEditingController();
  final _json = TextEditingController();
  String _icon = 'link';
  String? _error;
  bool _aiBusy = false;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    // Изменение — сразу вкладка JSON: только она обратимо описывает ЛЮБОЕ
    // сочетание заголовков/тела, с которым сервис мог быть создан
    // изначально (через ссылку+ключ или curl восстановить точно так же
    // не получится — там на входе всегда только часть возможных полей).
    _tab = TabController(length: 3, vsync: this, initialIndex: existing == null ? 0 : 2);
    if (existing != null) {
      _name.text = existing.name;
      _icon = existing.iconName;
      _json.text = const JsonEncoder.withIndent('  ').convert({
        'url': existing.url,
        'method': existing.method,
        if (existing.headers.isNotEmpty) 'headers': existing.headers,
        if (existing.body != null) 'body': existing.body,
      });
    }
  }

  @override
  void dispose() {
    _tab.dispose();
    _name.dispose();
    _url.dispose();
    _apiKey.dispose();
    _curl.dispose();
    _json.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Введите название');
      return;
    }
    ParsedConnection parsed;
    try {
      parsed = switch (_tab.index) {
        1 => ServiceConnectionParser.fromCurl(_curl.text),
        2 => ServiceConnectionParser.fromJson(_json.text),
        _ => ServiceConnectionParser.fromUrl(_url.text),
      };
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    // Ключ API на вкладке "Ссылка" — самый частый случай авторизации
    // (решение пользователя: без этого поля пришлось бы идти во вкладку
    // cURL/JSON только ради одного заголовка, а без заголовка запрос к
    // защищённому API либо открывается как есть внешней ссылкой и
    // показывает голую ошибку авторизации в браузере, либо не работает).
    if (_tab.index == 0 && _apiKey.text.trim().isNotEmpty) {
      parsed = ParsedConnection(
        url: parsed.url,
        method: parsed.method,
        headers: {...parsed.headers, 'Authorization': 'Bearer ${_apiKey.text.trim()}'},
        body: parsed.body,
      );
    }
    final existing = widget.existing;
    if (existing == null) {
      widget.repo.add(
        name: _name.text.trim(),
        iconName: _icon,
        url: parsed.url,
        method: parsed.method,
        headers: parsed.headers,
        body: parsed.body,
      );
    } else {
      widget.repo.update(
        existing.id,
        name: _name.text.trim(),
        iconName: _icon,
        url: parsed.url,
        method: parsed.method,
        headers: parsed.headers,
        body: parsed.body,
      );
    }
    Navigator.of(context).pop();
  }

  /// "Заполнить с ИИ" (решение пользователя: должно быть прямо в
  /// настройках сервиса, не в общем чате с ассистентом) — вставляешь
  /// одним куском название/ссылку/ключ, как они есть, а модель сама
  /// раскладывает их по полям формы (вкладка JSON) — не нужно вручную
  /// собирать `{"headers": {"Authorization": ...}}`.
  Future<void> _fillWithAi() async {
    final controller = TextEditingController();
    final pasted = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Заполнить с ИИ'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: 'Вставьте как есть: название сервиса, ссылку, ключ API — что есть',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Заполнить'),
          ),
        ],
      ),
    );
    if (pasted == null || pasted.isEmpty || !mounted) return;

    setState(() {
      _aiBusy = true;
      _error = null;
    });
    try {
      final aiSettings = AiSettings(context.read<AppDataStore>().db);
      final reply = await AiService(aiSettings).ask(
        systemPrompt: 'Ты помогаешь разобрать описание стороннего сервиса/API на структурированные поля. '
            'Тебе дан произвольный текст — обычно вперемешку название, ссылка и ключ доступа. '
            'Ответь ТОЛЬКО JSON-объектом без пояснений, без markdown, без ```: '
            '{"name": "короткое название сервиса", "url": "адрес API или сайта", '
            '"method": "GET или POST, по умолчанию GET", '
            '"headers": {"Authorization": "Bearer ключ, если он есть в тексте"}}. '
            'Поле headers — объект, пустой {} если ключа/заголовков в тексте нет. '
            'Если явного названия сервиса нет — придумай короткое по домену ссылки.',
        contextBlock: '',
        history: [(role: 'user', text: pasted)],
      );
      final decoded = jsonDecode(_stripCodeFence(reply.text));
      if (decoded is! Map) throw const FormatException('Ассистент ответил не JSON-объектом');
      setState(() {
        if (decoded['name'] != null) _name.text = '${decoded['name']}';
        _tab.index = 2;
        _json.text = const JsonEncoder.withIndent('  ').convert({
          'url': decoded['url'],
          'method': decoded['method'] ?? 'GET',
          'headers': decoded['headers'] ?? {},
        });
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось разобрать: $e');
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  /// На случай, если модель всё же обернула ответ в ```json — снимаем
  /// код-забор, а не отклоняем ответ целиком.
  String _stripCodeFence(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('```')) return trimmed;
    final withoutStart = trimmed.replaceFirst(RegExp(r'^```[a-zA-Z]*\n?'), '');
    return withoutStart.replaceFirst(RegExp(r'```\s*$'), '').trim();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Изменить сервис' : 'Новый сервис'),
        actions: [
          IconButton(
            icon: _aiBusy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome_outlined),
            tooltip: 'Заполнить с ИИ',
            onPressed: _aiBusy ? null : _fillWithAi,
          ),
          TextButton(onPressed: _save, child: Text(_editing ? 'СОХРАНИТЬ' : 'СОЗДАТЬ')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Название'),
          ),
          const SizedBox(height: 16),
          const Text('Значок'),
          const SizedBox(height: 8),
          ServiceIconPicker(selected: _icon, onChanged: (v) => setState(() => _icon = v)),
          const SizedBox(height: 20),
          TabBar(
            controller: _tab,
            tabs: const [Tab(text: 'Ссылка'), Tab(text: 'cURL'), Tab(text: 'JSON')],
            onTap: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: 12),
          AnimatedBuilder(
            animation: _tab,
            builder: (context, _) => IndexedStack(
              index: _tab.index,
              children: [
                Column(
                  children: [
                    TextField(
                      controller: _url,
                      decoration: const InputDecoration(
                        labelText: 'Ссылка',
                        hintText: 'https://drive.google.com/...',
                      ),
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _apiKey,
                      decoration: const InputDecoration(
                        labelText: 'Ключ API (необязательно)',
                        hintText: 'Если сервис требует авторизацию',
                      ),
                      autocorrect: false,
                      obscureText: true,
                    ),
                  ],
                ),
                TextField(
                  controller: _curl,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Команда curl',
                    hintText: "curl -H 'Authorization: Bearer ...' https://...",
                    alignLabelWithHint: true,
                  ),
                  autocorrect: false,
                ),
                TextField(
                  controller: _json,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'JSON',
                    hintText: '{"url": "https://...", "headers": {"Authorization": "Bearer ..."}}',
                    alignLabelWithHint: true,
                  ),
                  autocorrect: false,
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 16),
          Text(
            'Простая ссылка (без ключа и заголовков) открывается как обычный сайт. '
            'Если задан ключ API, заголовки или тело запроса — плитка выполняет запрос '
            'внутри приложения и показывает ответ, а не открывает страницу с ошибкой авторизации.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Данные (в том числе ключи доступа) хранятся только на этом устройстве — '
            'так же, как остальные настройки приложения.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
