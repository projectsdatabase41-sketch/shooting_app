import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../models/custom_service.dart';

/// Экран одной плитки сервиса — простую ссылку (без заголовков) сразу
/// открывает во внешнем браузере/приложении и не задерживает на себе
/// (решение пользователя: сервис — это, как правило, целый сайт вроде
/// Google Диска, показывать вместо него что-то своё незачем). Если
/// заданы заголовки или тело запроса (похоже на доступ к API) —
/// выполняет запрос сам и показывает ответ, поскольку заголовки
/// (авторизацию) внешний браузер передать не может.
class ServiceTileScreen extends StatefulWidget {
  final CustomService service;
  const ServiceTileScreen({super.key, required this.service});

  @override
  State<ServiceTileScreen> createState() => _ServiceTileScreenState();
}

class _ServiceTileScreenState extends State<ServiceTileScreen> {
  bool _busy = false;
  String? _response;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.service.isPlainLink) {
      // После кадра — открывать внешнюю ссылку прямо из initState
      // слишком рано (BuildContext ещё не готов для Navigator.pop).
      WidgetsBinding.instance.addPostFrameCallback((_) => _openLink());
    } else {
      _runRequest();
    }
  }

  Future<void> _openLink() async {
    await launchUrl(Uri.parse(widget.service.url), mode: LaunchMode.externalApplication);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _runRequest() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final s = widget.service;
    try {
      final uri = Uri.parse(s.url);
      final http.Response res;
      switch (s.method) {
        case 'POST':
          res = await http.post(uri, headers: s.headers, body: s.body);
        case 'PUT':
          res = await http.put(uri, headers: s.headers, body: s.body);
        case 'DELETE':
          res = await http.delete(uri, headers: s.headers, body: s.body);
        default:
          res = await http.get(uri, headers: s.headers);
      }
      final text = utf8.decode(res.bodyBytes);
      setState(() => _response = '${res.statusCode}\n\n${_prettyIfJson(text)}');
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _prettyIfJson(String text) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    } catch (_) {
      return text;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.service.isPlainLink) {
      // Пока не сработал postFrameCallback выше — просто крутилка,
      // экран висит на глазах доли секунды.
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.service.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: 'Открыть ссылку в браузере',
            onPressed: () => launchUrl(Uri.parse(widget.service.url), mode: LaunchMode.externalApplication),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _runRequest,
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    SelectableText(_response ?? '', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  ],
                ),
      floatingActionButton: _response == null
          ? null
          : FloatingActionButton.small(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _response!));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ответ скопирован')));
              },
              child: const Icon(Icons.copy),
            ),
    );
  }
}
