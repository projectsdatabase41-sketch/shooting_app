import 'package:flutter/material.dart';

import '../logic/service_connection_parser.dart';
import '../services/custom_services_repository.dart';
import '../widgets/service_icon_picker.dart';

/// Добавление плитки стороннего сервиса — три способа описать
/// подключение (решение пользователя): просто ссылка, cURL-команда или
/// JSON. Все три в итоге дают один и тот же набор полей
/// (`ParsedConnection`) — вкладки только про удобство ввода.
class AddServiceScreen extends StatefulWidget {
  final CustomServicesRepository repo;
  const AddServiceScreen({super.key, required this.repo});

  @override
  State<AddServiceScreen> createState() => _AddServiceScreenState();
}

class _AddServiceScreenState extends State<AddServiceScreen> with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _curl = TextEditingController();
  final _json = TextEditingController();
  String _icon = 'link';
  String? _error;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    _name.dispose();
    _url.dispose();
    _curl.dispose();
    _json.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Введите название');
      return;
    }
    final ParsedConnection parsed;
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
    widget.repo.add(
      name: _name.text.trim(),
      iconName: _icon,
      url: parsed.url,
      method: parsed.method,
      headers: parsed.headers,
      body: parsed.body,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Новый сервис'),
        actions: [TextButton(onPressed: _save, child: const Text('СОЗДАТЬ'))],
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
          IndexedStack(
            index: _tab.index,
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
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 16),
          Text(
            'Простая ссылка (без заголовков) открывается как обычный сайт. '
            'Если заданы заголовки или тело запроса (обычно так выглядит доступ к API) — '
            'плитка ещё и предложит выполнить запрос внутри приложения и показать ответ.',
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
