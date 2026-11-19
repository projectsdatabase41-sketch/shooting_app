import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../i18n/i18n.dart';
import '../services/chat_auth_service.dart';
import '../services/pdf_tools_service.dart';
import '../state/app_data_store.dart';
import '../widgets/app_backdrop.dart';
import '../widgets/glass_pill.dart';

/// PDF-инструменты: объединить, разделить, сжать, конвертировать и прочее.
/// Обработка идёт на нашем сервере (iLoveAPI), ключ в приложении не хранится.
/// Пока ключ не выдан, экран честно говорит «модуль не настроен».
class PdfToolsScreen extends StatefulWidget {
  const PdfToolsScreen({super.key});

  @override
  State<PdfToolsScreen> createState() => PdfToolsScreenState();
}

class PdfToolsScreenState extends State<PdfToolsScreen> {
  late final PdfToolsService _service;
  String _tool = 'merge';
  List<({String name, Uint8List bytes})> _files = const [];
  bool _busy = false;
  String? _message;
  Uint8List? _result;

  @override
  void initState() {
    super.initState();
    _service = PdfToolsService(ChatAuthService(context.read<AppDataStore>().db));
  }

  bool get _single => PdfToolsService.singleFileTools.contains(_tool);

  Future<void> _pick() async {
    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: !_single,
      withData: true,
    );
    if (picked == null) return;
    final files = <({String name, Uint8List bytes})>[];
    for (final f in picked.files) {
      final bytes = f.bytes;
      if (bytes != null) files.add((name: f.name, bytes: bytes));
    }
    if (files.isEmpty) return;
    setState(() {
      _files = _single ? files.take(1).toList() : files;
      _result = null;
      _message = null;
    });
  }

  Future<void> _run() async {
    if (_files.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _result = null;
    });
    try {
      final uploaded = <({String id, String name})>[];
      for (final f in _files) {
        final up = await _service.upload(f.bytes, f.name);
        if (up == null) {
          setState(() => _message = tr('Не удалось загрузить файл: {n}', {'n': f.name}));
          return;
        }
        uploaded.add(up);
      }
      final id = await _service.run(_tool, uploaded);
      if (id == null) {
        setState(() {
          _message = PdfToolsService.notConfigured
              ? tr('Модуль PDF ещё не настроен: нужен ключ iLoveAPI на сервере.')
              : tr('Не получилось обработать файл. Попробуйте ещё раз.');
        });
        return;
      }
      final out = await _service.download(id);
      if (!mounted) return;
      setState(() {
        _result = out;
        _message = out == null ? tr('Результат не скачался') : tr('Готово');
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    final data = _result;
    if (data == null) return;
    try {
      final dir = await getTemporaryDirectory();
      final name = '${_tool}_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(data);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'application/pdf')],
        subject: tr('PDF-инструменты'),
      ));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(title: Text(tr('PDF-инструменты'))),
      body: AppBackdrop(
        kind: 'settings',
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + GlassHeader.height + 12, 16, 32),
          children: [
            Text(tr('Файлы обрабатываются на нашем сервере: объединить, разделить, сжать, перевести в PDF и обратно, поставить номера страниц или водяной знак. Файлы не сохраняются в приложении.'),
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _tool,
              decoration: InputDecoration(labelText: tr('Что сделать')),
              items: [
                for (final e in PdfToolsService.tools.entries)
                  DropdownMenuItem(value: e.key, child: Text(tr(e.value))),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                        _tool = v ?? _tool;
                        _files = const [];
                        _result = null;
                        _message = null;
                      }),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _pick,
                  icon: const Icon(Icons.attach_file),
                  label: Text(tr('Выбрать файлы')),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _files.isEmpty || _busy ? null : _run,
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.bolt),
                label: Text(tr('Обработать')),
              ),
            ]),
            if (_files.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final f in _files)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.picture_as_pdf_outlined),
                  title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${(f.bytes.length / 1024).round()} КБ'),
                ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!, style: theme.textTheme.bodyMedium),
            ],
            if (_result != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _share,
                icon: const Icon(Icons.ios_share),
                label: Text(tr('Поделиться результатом')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
